--
-- Copyright 2023 The Android Open Source Project
--
-- Licensed under the Apache License, Version 2.0 (the "License");
-- you may not use this file except in compliance with the License.
-- You may obtain a copy of the License at
--
--     https://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.
--

INCLUDE PERFETTO MODULE linux.cpu.utilization.thread;
INCLUDE PERFETTO MODULE linux.cpu.utilization.slice;
INCLUDE PERFETTO MODULE slices.with_context;
INCLUDE PERFETTO MODULE slices.cpu_time;

SELECT RUN_METRIC('android/android_cpu.sql');
SELECT RUN_METRIC('android/power_drain_in_watts.sql');

-- Attaching thread proto with media thread name
DROP VIEW IF EXISTS core_type_proto_per_thread_name;
CREATE PERFETTO VIEW core_type_proto_per_thread_name AS
SELECT
utid,
thread.name AS thread_name,
core_type_proto_per_thread.proto AS proto
FROM core_type_proto_per_thread
JOIN thread using(utid)
WHERE thread.name = 'MediaCodec_loop' OR
      thread.name = 'CodecLooper'
GROUP BY thread.name;

-- All process that has codec thread
DROP TABLE IF EXISTS android_codec_process;
CREATE PERFETTO TABLE android_codec_process AS
SELECT
  utid,
  upid,
  process.name AS process_name
FROM thread
JOIN process using(upid)
WHERE thread.name = 'MediaCodec_loop' OR
      thread.name = 'CodecLooper'
GROUP BY process_name, thread.name;

-- Getting cpu cycles for the threads
DROP VIEW IF EXISTS cpu_cycles_runtime;
CREATE PERFETTO VIEW cpu_cycles_runtime AS
SELECT
  utid,
  megacycles,
  runtime,
  proto,
  process_name,
  thread_name
FROM android_codec_process
JOIN cpu_cycles_per_thread using(utid)
JOIN core_type_proto_per_thread_name using(utid);

-- Traces are collected using specific traits in codec framework. These traits
-- are mapped to actual names of slices and then combined with other tables to
-- give out the total_cpu and cpu_running time.

-- Utility function to trim codec trace string: extract the string demilited
-- by the limiter.
CREATE OR REPLACE PERFETTO FUNCTION extract_codec_string(slice_name STRING, limiter STRING)
RETURNS STRING AS
SELECT CASE
  -- Delimit with the first occurrence
  WHEN instr($slice_name, $limiter) > 0
  THEN substr($slice_name, 1, instr($slice_name, $limiter) - 1)
  ELSE $slice_name
END;

-- Traits strings from codec framework
DROP TABLE IF EXISTS trace_trait_table;
CREATE TABLE trace_trait_table(trace_trait TEXT UNIQUE);
INSERT INTO trace_trait_table VALUES
  ('MediaCodec::'),
  ('CCodec::'),
  ('CCodecBufferChannel::'),
  ('C2PooledBlockPool::'),
  ('C2hal::'),
  ('ACodec::'),
  ('FrameDecoder::');

-- Maps traits to slice strings. Any string with '@' is considered to indicate
-- the same trace with different information.Hence those strings are delimited
-- using '@' and considered as part of single slice.

-- View to hold slice ids(sid) and the assigned slice ids for codec slices.
DROP TABLE IF EXISTS codec_slices;
CREATE PERFETTO TABLE codec_slices AS
WITH
  __codec_slices AS (
    SELECT DISTINCT
      extract_codec_string(name, '@') AS codec_string,
      slice.id AS sid,
      slice.name AS sname
    FROM slice
    JOIN trace_trait_table ON slice.name glob trace_trait || '*'
  ),
  _codec_slices AS (
    SELECT DISTINCT codec_string,
      ROW_NUMBER() OVER() AS codec_slice_idx
    FROM __codec_slices
    GROUP BY codec_string
  )
SELECT
  codec_slice_idx,
  a.codec_string,
  sid
FROM __codec_slices a
JOIN _codec_slices b USING(codec_string);

-- Combine slice and and cpu dur and cycles info
DROP TABLE IF EXISTS codec_slice_cpu_running;
CREATE PERFETTO TABLE codec_slice_cpu_running AS
SELECT
  codec_string,
  MIN(ts) AS ts,
  MAX(ts + t.dur) AS max_ts,
  SUM(t.dur) AS dur,
  SUM(ct.cpu_time) AS cpu_run_ns,
  SUM(megacycles) AS cpu_cycles,
  cc.thread_name,
  cc.process_name
FROM codec_slices
JOIN thread_slice t ON(sid = t.id)
JOIN thread_slice_cpu_cycles cc ON(sid = cc.id)
JOIN thread_slice_cpu_time ct ON(sid = ct.id)
GROUP BY codec_slice_idx, cc.thread_name, cc.process_name;

-- POWER consumed during codec use.
-- Create a map for the distinct power names.
DROP TABLE IF EXISTS power_rail_name_mapping;
CREATE PERFETTO TABLE power_rail_name_mapping AS
SELECT DISTINCT name,
  ROW_NUMBER() OVER() AS idx
FROM drain_in_watts GROUP by name;

-- Extract power data for the codec running duration.
DROP TABLE IF EXISTS mapped_drain_in_watts;
CREATE PERFETTO TABLE mapped_drain_in_watts AS
WITH
  start_ts AS (
    SELECT MIN(ts) AS ts
    FROM codec_slice_cpu_running
    WHERE codec_string glob "CCodecBufferChannel::queue" || '*'
  ),
  end_ts AS (
    SELECT MAX(max_ts) as ts
    FROM codec_slice_cpu_running
    WHERE codec_string glob "CCodecBufferChannel::onWorkDone" || '*'
  )
SELECT d.name, d.ts, dur, drain_w, idx
FROM drain_in_watts d
JOIN power_rail_name_mapping p ON (d.name = p.name)
JOIN start_ts
JOIN end_ts
WHERE d.ts >= start_ts.ts AND d.ts <= end_ts.ts;

-- Get the total energy for the time of run.
CREATE OR REPLACE PERFETTO FUNCTION get_energy_duration()
RETURNS DOUBLE AS
SELECT  CAST(((MAx(ts + dur) - MIN(ts)) / 1e6) AS INT64) AS total_duration_ms
FROM mapped_drain_in_watts;

-- Get the subssytem based power breakdown
DROP TABLE IF EXISTS mapped_drain_in_watts_with_subsystem;
CREATE PERFETTO TABLE mapped_drain_in_watts_with_subsystem AS
WITH
   total_duration_ms AS (
     SELECT CAST(((MAx(ts + dur) - MIN(ts)) / 1e6) AS INT64) AS total_dur FROM mapped_drain_in_watts
   ),
   total_energy AS (
     SELECT cast_double!(SUM((dur * drain_w) / 1e9)) AS total_joules FROM mapped_drain_in_watts
   )
SELECT
  SUM((dur * drain_w) / 1e9) AS joules_subsystem,
  total_dur,
  total_joules,
  subsystem
FROM mapped_drain_in_watts
JOIN total_duration_ms
JOIN total_energy
JOIN power_counters USING(name)
GROUP BY subsystem;

-- Generate proto for the trace
DROP VIEW IF EXISTS metrics_per_slice_type;
CREATE PERFETTO VIEW metrics_per_slice_type AS
SELECT
  process_name,
  codec_string,
  AndroidCodecMetrics_Detail(
    'thread_name', thread_name,
    'total_cpu_ns', CAST(dur AS INT64),
    'running_cpu_ns', CAST(cpu_run_ns AS INT64),
    'cpu_cycles', CAST(cpu_cycles AS INT64)
  ) AS proto
FROM codec_slice_cpu_running;

-- Generating codec framework cpu metric
DROP VIEW IF EXISTS codec_metrics_output;
CREATE PERFETTO VIEW codec_metrics_output AS
SELECT AndroidCodecMetrics(
  'cpu_usage', (
    SELECT RepeatedField(
      AndroidCodecMetrics_CpuUsage(
        'process_name', process_name,
        'thread_name', thread_name,
        'thread_cpu_ns', CAST((runtime) AS INT64),
        'core_data', proto
      )
    ) FROM cpu_cycles_runtime
  ),
  'codec_function', (
    SELECT RepeatedField (
      AndroidCodecMetrics_CodecFunction(
        'codec_string', codec_string,
        'process_name', process_name,
        'detail', metrics_per_slice_type.proto
      )
    ) FROM metrics_per_slice_type
  ),
  'energy_usage',
    AndroidCodecMetrics_EnergyUsage(
      'total_energy', (SELECT total_joules FROM mapped_drain_in_watts_with_subsystem),
      'duration', (SELECT total_dur FROM mapped_drain_in_watts_with_subsystem),
      'subsystem', (
        SELECT RepeatedField (
          AndroidCodecMetrics_EnergyBreakdown (
            'subsystem', subsystem,
            'energy', CAST((joules_subsystem) AS DOUBLE)
          )
        ) FROM mapped_drain_in_watts_with_subsystem
     )
  )
);

# PIG (Process/Thread Migration) Benchmark Wrapper

## Description

This wrapper facilitates the automated execution of Bill Gray's pig benchmark. Pig is a tool designed to measure process/thread migration rates and scheduling efficiency of a system, reporting how effectively the kernel scheduler distributes work across CPUs. The benchmark supports multiple load types (spin, sleep, integer, FPU, memory, dirty) and provides detailed per-CPU thread migration tallies.

The wrapper provides:
- Automated pig download, build, and execution.
- Support for x86_64 and aarch64 architectures.
- Automatic CPU topology detection and incremental thread scaling.
- Configurable test parameters via direct options or parameter files.
- Regression mode for quick validation runs.
- Result collection, processing, and CSV generation with scheduling efficiency metrics.
- System configuration metadata capture.
- Integration with test_tools framework.
- Optional Performance Co-Pilot (PCP) integration.

## Command-Line Options

```
Pig Options:
  --pig_opts <value>: Options to pass directly to the pig binary.
      Format is "suffix:options" when using parameter files.
  --regression: Run a limited pig test: 8 data points, 120 seconds each point.
      Useful for quick validation runs.

General test_tools options:
  --home_parent <value>: Parent home directory. If not set, defaults to current working directory.
  --host_config <value>: Host configuration name, defaults to current hostname.
  --iterations <value>: Number of times to run the test, defaults to 1.
  --run_user: User that is actually running the test on the test system. Defaults to current user.
  --sys_type: Type of system working with (aws, azure, hostname). Defaults to hostname.
  --sysname: Name of the system running, used in determining config files. Defaults to hostname.
  --tuned_setting: Used in naming the results directory. For RHEL, defaults to current active tuned profile.
      For non-RHEL systems, defaults to 'none'.
  --use_pcp: Enable Performance Co-Pilot monitoring during test execution.
  --tools_git <value>: Git repo to retrieve the required tools from.
      Default: https://github.com/redhat-performance/test_tools-wrappers
  --usage: Display this usage message.
```

## What the Script Does

The `run_pig.sh` script performs the following workflow:

1. **Environment Setup**:
   - Clones the test_tools-wrappers repository if not present (default: ~/test_tools).
   - Sources general setup utilities for test configuration.
   - Parses command-line options for pig-specific and general test parameters.

2. **Package Installation**:
   - Installs required dependencies via package_tool using `pig.json`.
   - Dependencies are defined for different OS variants (RHEL, Ubuntu, SLES, Amazon Linux).

3. **PCP Setup** (if `--use_pcp` is enabled):
   - Sources PCP command library and initializes PCP logging.
   - Configures PCP data collection directory with timestamp.

4. **Parameter File Check**:
   - Checks for a parameters file matching the host configuration and test name.
   - If found, iterates through each line as pig options.
   - If not found, runs with default options.

5. **Pig Build**:
   - Compiles pig from source if the binary is not already present.
   - Build command: `gcc pig.c -o pig -lm -lpthread -lnuma`.

6. **System Information Collection**:
   - Detects total CPU count from `/sys/devices/system/cpu/`.
   - Records system date, kernel version, boot command line.
   - Captures lscpu output, NUMA settings, scheduler parameters.
   - Records transparent hugepage configuration.

7. **Thread Increment Calculation**:
   - Divides total CPUs into a configurable number of data points (default: 8).
   - Starts at 1 thread and increments evenly up to total CPUs.
   - For systems with fewer CPUs than data points, increments by 1.

8. **Test Execution**:
   - Runs pig in verbose mode (`-v`) with 1 process (`-p 1`).
   - Iterates through each thread count from the calculated increments.
   - Each run executes for 99 seconds by default (120 seconds in regression mode).
   - Sleeps 30 seconds between each thread count to allow system stabilization.
   - Repeats for the specified number of iterations.

9. **Data Collection**:
   - Captures per-thread CPU migration tallies and work distribution.
   - Records scheduling efficiency (#CPUS vs threads) for each data point.
   - Stores raw output in iteration files within the results directory.

10. **Result Processing**:
    - Extracts CPU count and thread count from iteration output.
    - Calculates scheduling efficiency ratio (CPUs used / threads requested).
    - Generates CSV file with header information and thread:efficiency data pairs.
    - Creates human-readable results summary.
    - Writes pass/fail status to test_results_report.

11. **Output**:
    - Creates results directory named `results_pig_<tuned_setting>/`.
    - Saves all raw output files, processed CSV, and system metadata.
    - Optionally saves PCP performance data.
    - Archives results via `save_results` for later analysis.

## Dependencies

Location of underlying workload: Built from source (`pig.c`) included in the wrapper repository.

**General packages required**: gcc, git, zip, unzip, bc

**Additional OS-specific packages**:
- RHEL: perf, numactl-devel.
- Ubuntu: libnuma-dev.
- SLES: libnuma-devel.
- Amazon Linux: numactl-devel, numactl-libs.

To run:
```bash
git clone https://github.com/redhat-performance/pig_wrapper
cd pig_wrapper/pig
./run_pig.sh
```

The script will automatically detect your CPU topology and calculate thread increments.

## The Pig Benchmark

Pig is a workload generator designed to stress test CPU scheduling and measure thread migration behavior. It creates processes and threads that perform configurable work, then reports how the kernel scheduler distributed those threads across CPUs.

### Key Pig Parameters

1. **Processes (`-p N`)**: Number of processes to fork. Each process runs independently with its own set of threads.

2. **Threads (`-t N`)**: Number of threads per process. The wrapper scales this from 1 to total CPUs to measure scheduling efficiency at different levels of contention.

3. **Run Time (`-s N`)**: Duration in seconds for each test point. Default is 99 seconds; regression mode uses 120 seconds.

4. **Load Type (`-l <LOAD>`)**: The type of work each thread performs:
   - `spin`: Default. CPU spin loop with variable utilization (`-k MIN:MAX`).
   - `sleep`: Threads mostly sleep. Useful for memory-only testing.
   - `int`: Integer arithmetic workload.
   - `fpu`: Floating-point workload (sin, sqrt operations).
   - `mem`: Memory load with pointer-chasing reads (optionally writes with `-w`).
   - `dirty`: Writes to random memory locations (`-n N` locations per second).

5. **Memory (`-m N`)**: Allocate N megabytes per thread (or per process with `-G`).

6. **Process Binding (`-r`)**: Round-robin bind processes to NUMA nodes for controlled placement.

7. **CPU Utilization (`-k MIN:MAX`)**: Set minimum and maximum CPU utilization percentage for spin load.

8. **Intermittent Load (`-i WORK:REST`)**: Alternate between WORK seconds of activity and REST seconds of idle.

### Memory Attributes

- `-G`: Global per-process memory (rather than per-thread).
- `-I`: Interleaved memory allocation across NUMA nodes.
- `-H`: Use static huge pages.
- `-T`: Use transparent huge pages.
- `-N`: Disable transparent huge pages.
- `-M`: Use mergeable memory (KSM).
- `-S`: Use shared anonymous memory (incompatible with `-M` and `-T`).
- `-L N`: Set memory load stride length (default: 57 64-bit words).

### Performance Metric

The primary metric is **scheduling efficiency** (`sched_eff`), calculated as:

```
sched_eff = #CPUs_used / #threads_requested
```

A value of 1.0 indicates perfect scheduling: each thread ran on exactly one CPU with no migrations. Values greater than 1.0 indicate thread migrations across CPUs. Lower values are better.

In verbose mode, pig also reports per-thread work done (arbitrary units) with average, standard deviation, minimum, and maximum across threads.

## Output Files

The results directory contains:

- **results_pig.csv**: CSV file with scheduling efficiency data (threads vs. sched_eff).
- **iteration_N**: Raw pig output for each iteration, showing per-CPU thread tallies and work distribution.
- **pig_config_info**: System configuration snapshot (date, kernel, lscpu, NUMA settings, scheduler parameters, THP settings).
- **results.txt**: Human-readable results summary table.
- **test_results_report**: Pass/fail status (`Ran` or `Failed`).
- **PCP data** (if --use_pcp option used): Performance Co-Pilot monitoring data


## Examples

### Basic run with defaults
```bash
./run_pig.sh
```
This runs with:
- 8 data points (thread counts scaled from 1 to total CPUs)
- 99 seconds per data point
- 1 iteration
- Automatic CPU topology detection

### Run regression test
```bash
./run_pig.sh --regression
```
Runs with 8 data points at 120 seconds each for quick validation.

### Run multiple iterations
```bash
./run_pig.sh --iterations 3
```
Runs the full test 3 times to check consistency.

### Run with custom pig options
```bash
./run_pig.sh --pig_opts "memtest:-l mem -m 4000"
```
Passes custom options directly to pig. Format is `suffix:options`.

### Run with PCP monitoring
```bash
./run_pig.sh --use_pcp
```
Collects Performance Co-Pilot data during the run.

### Run with specific system configuration
```bash
./run_pig.sh --run_user root --home_parent / --iterations 1 --tuned_setting tuned_none_sys_file_none --host_config hawkeye --sysname hawkeye --sys_type local
```
Specifies user, home directory, tuned profile, host configuration, and system type for result organization.

### Combination example
```bash
./run_pig.sh --iterations 3 --regression --use_pcp
```
Runs 3 iterations of the regression test with PCP data collection.

## How Thread Scaling Works

The wrapper automatically calculates thread counts to test based on system CPU count:

### Data Points
1. Detects total CPU count from `/sys/devices/system/cpu/`.
2. Subtracts 2 from total to leave headroom for OS processes.
3. Divides remaining CPUs into N data points (default: 8, configurable via `run_pig -P`).
4. If `--regression` is used, fixes at 8 data points with 120 seconds per point.

### Thread Count Calculation
1. Calculates increment: `increment = available_cpus / points`.
2. Calculates starting offset to ensure the final data point is always the maximum CPU count.
3. If starting offset is greater than 1, adds an initial data point at 1 thread.
4. Generates thread counts from the starting offset up to max CPUs, incrementing evenly.

### Example on a 64-CPU System
With 8 data points and 62 usable CPUs (64 - 2):
- Increment = 7 (62 / 8)
- Starting offset = 6 (62 - 7*8 + 7)
- Thread counts: 1, 6, 13, 20, 27, 34, 41, 48, 55, 62

### Test Execution Order
For each iteration:
1. Walk through each thread count in order.
2. Run pig with that thread count for the configured duration.
3. Sleep 30 seconds between data points.
4. Repeat for next iteration.

## Return Codes

The script uses standard exit codes:
- **0**: Success
- **Non-zero**: Failure (package installation failure, pig build failure, or test execution failure)

The `test_results_report` file indicates test outcome:
- **Ran**: Test completed successfully with valid data (more than 2 lines in CSV)
- **Failed**: Test did not produce sufficient output data

## Notes

### Architecture Support
- **x86_64**: Full support for AMD and Intel CPUs.
- **aarch64**: Full support for ARM CPUs.
- Pig uses architecture-specific timing mechanisms (TSC on x86_64, clock_gettime on ARM).

### What Pig Measures
- Pig measures how many CPUs each thread ran on during the test period.
- Ideal scheduling means each thread stays on one CPU (sched_eff = 1.0).
- Thread migrations increase sched_eff above 1.0 and indicate scheduler overhead.
- The verbose mode (`-v`) shows a full per-CPU tally matrix, useful for diagnosing migration patterns.

### Load Types and Use Cases
- **Spin load** is the default and best for measuring raw scheduler behavior.
- **Memory load** (`-l mem`) stresses the memory subsystem and NUMA effects. Pinned processes (`-r`) typically show much higher work throughput than unpinned.
- **FPU load** (`-l fpu`) generates floating-point work (sin, sqrt) for testing FPU scheduling.
- **Dirty load** (`-l dirty`) writes to random memory locations, useful for testing memory write patterns.
- **Sleep load** (`-l sleep`) is useful for simulating idle VMs that consume memory without CPU work.

### Performance Tips
- Run multiple iterations to verify consistency.
- Ensure system is idle (no other workloads) for best results.
- Disable CPU frequency scaling (use performance governor) for reproducible results.
- Consider the active tuned profile on RHEL systems.
- For production benchmarking, allow system to warm up with a test run first.

### NUMA Considerations
- Use the `-r` flag with pig to round-robin bind processes to NUMA nodes.
- Pinned memory loads show significantly higher throughput than unpinned (up to 2x improvement).
- NUMA settings are automatically captured in system metadata for analysis.

### Troubleshooting
- If pig fails to build, verify that `gcc`, `numactl-devel` (or `libnuma-dev` on Ubuntu), and `bc` are installed.
- If performance is unexpectedly low, check CPU frequency and system load.
- Use `--use_pcp` to collect detailed performance counters for analysis.
- For additional details, see `pig_doc.txt` and `pig_examples.txt` provided with the pig tool.

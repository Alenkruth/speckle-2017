SPEC2017 Port
=============================

   This branch is a WIP and changes Speckle's usage model. It removes run support,
   and makes the copy mode the default.

   Key changes:
   - Host and Target configurations are provided.
   - A target SPEC2017 build is done to generate target binaries
   - A host SPEC2017 runsetup is done to complete generate a working directories
     for each benchmark.
   - The host directory is copyied to the overlay directory, host binaries are replaced
     with target binaries
   - A run script(run.sh) is generated that executes all the inputs for the benchmark
   
   
## Buld for Spike run

~~~

# make sure you have the linux-gnu cross-compiler installed
# and $RISCV properly defined.
. riscv_env

# set the SPEC CPU 2017 path
export SPEC_DIR=/path/to/SPEC_CPU_2017

# generate the intrate benchmarks
./gen_binaries.sh --compile --suite intrate --input ref

# generate the fprate benchmarks
./gen_binaries.sh --compile --suite fprate --input ref

# generate the intspeed benchmarks
./gen_binaries.sh --compile --suite intspeed --input ref

# generate the fpspeed benchmarks
./gen_binaries.sh --compile --suite fpspeed --input ref

# if sucessful, all files are located in
ls -l build/overlay/intrate
ls -l build/overlay/fprate
ls -l build/overlay/intspeed
ls -l build/overlay/fpspeed

~~~

Some extra fixes need to be done manually.

* Input 1 of 525.x264\_r (or 625.x264\_s) depends on the log output of input 0. Since we normally do not run the whole benchmark, we need to copy a prepared log to the running directory for running input 1:

~~~
cp -r 525.x264_r build/overlay/intrate/
cp -r 625.x264_s build/overlay/intspeed/
~~~

* 521.wrf\_r (or 621.wrf\_s) has a different running procedure. It lets wrf run to generate a putput file, and then using diffwrf to compare this output file with a prepared output for correctness. The script in Speckle seems to believe the following comparison as the main benchmark and generate a wrong running script. To fix this:
~~~
cp -r 521.wrf_r build/overlay/fprate/
cp -r 621.wrf_s build/overlay/fpspeed/
~~~


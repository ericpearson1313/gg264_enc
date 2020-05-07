# gg264_enc
Open source verilog for a FPGA hardware WebVC Video Encoder.

(FPGA = Field Programmable Gate Array)

(WebVC = simplefied compressed video format compatible with H.264)

## Purpose

Create a running encoder as a platform to showcase FPGA optimizations in areas of low latency, high throuput, and HLS synthesis.

Provide an example design of a minimum viable H.264 hardware real-time video encoder with rate-control. 

Using the MPEG WebVC video standard, "ISO/IEC 14496 Part 29: Web video coding"
- WebVC is an easier specfication to utilize vs. the full h.264 specification,
- Streams produced by WebVC are compatible with all deployed H.264 AVC decoders, 
- I was an editor for the WebVC standard, and would like to showcase it.

## Platform
Use AWS cloud fpgas, with their EC2 f1.2xlarge FPGA instances (Xilinx Vu9p) available on-demand. 
The runtime cost of $1.65/hr is affordable for hobbyist development. The 'F1 provides an available uniform platform for both open source hardware experimentation and scale deployment.
FPGA development tools are available at $0 additional cost, provided as an AMI to when creating new EC2 instances.

### EC2 Instances Emmployed
- f1.2xlarge - $1.65/hr - FPGA runtime instance
- r5.xlarge  - $0.25/hr - Full chip FPGA synthesis 
- r5.large   - $0.12/hr - Interactive block level synthesis sessions for $1/day

## Specifications

See my talk on WebVC and Open source hardware: [doc/webvc_talk_jan2020.pdf](doc/webvc_talk_jan2020.pdf)
for my intitial thoughts.

Since then I've been reducing the minimum hardware feature set for a first working version, 
where the video encoder can be run at realtime to measure performance and latency.

### Core Process module
A minimal hardware enocder, with the maximum potential, is centered around a transform block rate-distortion process encoder.
This is where hardware development will start. This process module will be intially implementented and verified as combinatorial logic.
Synthesis results will give area and timing. Then simulation will be used to functionally bring up the module. Timing and area optimization will follow. 
After which, the design will be pipelined to increase its throughput. At the earlies convenient time, a function video codec will be designed, with features added after.


## Planning
follow a process spiral of: plan, model, design, synthesis, simulate on each of the following:
- gg_process - the block encoder
- system - tbd simplified 1080p video encoder.

## Status

### Model
The C model can encode 720p video frames from a YUV files and output a valid bitstreams.
A known good decoder can be used to validate the output stream and match reconstructed data.
 
It is sufficient, for now, to provides a means to functionally bring up the transform block processing core.
(full verification is something else, and requires effort and rigor to acheive)

### Design
RTL has been written for the transform block rate-distortion process module. 
System Verilog was used with syntax checking provided in Vivado IDE 2018.3 running on desktop.

### Simulation

Minimal testbench added. Simulated using Vivado IDE 2018.3 running on desktop.
testcase MB0, 1st macroblock passing match with model.

### Synthesis
Interactive Vivado 2019.2 synthesis on AWS EC2 r5.large instance starting from FPGA Developer AMI AMI v1.8.2, using vivado 2019.2.

With most all warning removed and passing sims, the gg_process module is:

30586 Luts, and 48 DSP. At minimum 384 FF are needed for above/left/dc state.











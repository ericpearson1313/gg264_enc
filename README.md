# gg264_enc
Open source verilog for a FPGA hardware WebVC Video Encoder.

(FPGA = Field Programmable Gate Array)

(WebVC = simplefied compressed video format compatible with H.264)

## Greeting Message

Hello, this is an open source hardware public repository, accessible under the MIT open source license and wavier.
It contains an open source hardware video encoder, described in verilog RTL, for fpga deployment.
All code has been written by me based on public standards, practises, and knowledges.
The code is under development, and has not been publically promoted/advertised at this time.

If your looking at this repository now, you probably searched it out, knowing of me and maybe this project.
I'm fine to share with you.
I plan to achieve some pretty great results. 
Keep a watch here to see if/how good. 
I'll report operational performance measurements and reflect.
I hope someone gets some value from this project. I know I am.

## Purpose

Create a running video encoder as a platform to showcase FPGA optimizations for no compromise: low latency, high bitrate, fully WebVC compliant bitstreams. 

Using the MPEG WebVC video standard, "ISO/IEC 14496 Part 29: Web video coding"
- WebVC is an easier specfication to utilize vs. the full h.264 specification,
- Streams produced by WebVC are compatible with all deployed H.264 AVC decoders, 
- I was an editor for the MPEG WebVC standard, and would like to showcase it. (all be saddened that MPEG was dis-banded june 2020).

Provide a design of a minimum viable low latency H.264 hardware real-time 1080p, rate-controlled video encoder. 
The encoder could be used as-is with as capped vbr rate control enables communication over a limited bandwidth channel, 
and as a baseline platform for addition of video coding tools and quality tuning.

 
## Low Latency

Video latency can be defined as measured time from glass (lense) to glass (display). 
This makes latency minimization a system optimization issue, of which an encoder can be a significant portion.
For the hardware encoder, the similar latency definition can be measured from memory (full picture) input available to memory (coded picture) output complete.
If the input video can be raster input to the encoder, a much lower latency figure can be measured from the write of the last picture byte to dram, measure to the output of the last bit of the picture's bitstream. 

The target fpga operating frequency of 250 Mhz will give us latency of: 
- frame mem to mem: 1 msec, 
- raster video: 0.03 msec.

### Picture Slices

Using small slices can be beneficial to latency, as it allows earlier slice transmission, if then entire slice need be valid before transmission begins.
Small slice can allow parallel processing on the slices. 

However, a single slice picture has better compresssion and can achevie the same, or lower, latency of sliced streams if: transmission can begin as a encode chasing process, and decode can be started upon available reception data. 

At this time we look to have sufficient performance for single slice pictures. Slice parallel is feasiable, and can be implemented if and when required.

### GOP strucuture

For usec level latencies a all-P GOP (group of pictures) structure is requried.
Picture refresh is done on a sliding column of inter predicted macroblocks from a constant (128) reference picture.
A 'live' bitstream can be entered at any picture, however the decoder need first decode a stub bitstream which contains the long term reference IDR picture which is constant value = 128.
After entering the real time bistream and commencing receive data chasing decoding, the full picture video is available after all columns have refreshed, with the ongoing video being at the lowest feasible latency. 

## Rate Control

The TM5 rate control will be used as reference for the control loop.
NAL level rate control is used, as this reflect the actual transport data. (todo: NAL HDR VUI info).

The setpoint inputs are the desired qp and the peak bitrate allowed (CVBR), measured as bits over the LAB buffer lenght (120 macroblocks).

A video quality offset state, and a estimated total LAB bit count sum.

The video input is pre-encoded at the offset setpoint quality, and the bitrate recorded, and used to estimate the bitrate at other quality offsets. A qp offset of 6, doubles/halves the quantizer, which directly affects the bitrate. Finer control of the bits is available with quantization rouding controls.

The estimated total is updated with the assition of the newest macroblock bitcount, while subtraction the oldest macroblock actual bitcount. Bits added for byte aligned, or emuation 0x03 insertion are added. The LAB window rolls over pictures and slices and includes the slice header as well as any parameter set nals.

If the LAB bits are greater than the limit, then the macroblock qp's are increased until the lab bits fall within the limit (capped).

If the LAB bits are less than the limit, and any macroblocks have an offset qp, the qp's are adjusted towards the target.

The planned quantization parameters for the oldest macroblock are fixed, and bitcount will be updated to actual when the block is coded.

Using a LAB length in macroblocks to always include a column refresh macroblock allows evening out the average bits to meet the LAB bit limit.

## Platform

Use AWS cloud fpgas, with their EC2 f1.2xlarge FPGA instances (Xilinx Vu9p) available on-demand. 
The runtime cost of $1.65/hr is affordable for hobbyist development. The 'F1 provides an available uniform platform for both open source hardware experimentation and scale deployment.
FPGA development tools are available at $0 additional cost and provided as an AMI when creating new EC2 instances.

### EC2 Instances Emmployed
- f1.2xlarge - $1.65/hr - FPGA runtime instance
- r5.xlarge  - $0.25/hr - Full chip FPGA synthesis needs a 32GBytes instance. (There are faster, but this is the lowest $/build). 
- r5.large   - $0.12/hr - Interactive block level synthesis sessions for $1/day, works fine with a 16Gbyte instance.

## Specifications

See my talk on WebVC and Open source hardware: [doc/webvc_talk_jan2020.pdf](doc/webvc_talk_jan2020.pdf)
for my intitial thoughts.

Since then I've been reducing the minimum hardware feature set for a first working version, 
where the video encoder can be run at realtime to measure performance and latency.
I gave a progress update talk [doc/webvc_update_may2020_v2.pdf](doc/webvc_update_may2020_v2.pdf) which reflects my current planning and thoughts.

### Core Process module

A minimal hardware encoder, with the maximum potential, is centered around a transform block rate-distortion process encoder.
This is where hardware development will start. This process module will be intially implementented and verified as combinatorial logic.
Synthesis results will give area and timing. Then simulation will be used to functionally bring up the module. Timing and area optimization will follow. 
After which, the design will be pipelined to increase its throughput. A minimum viable functional video codec system will be designed to enable full rate operation
and enable measurments of performance and latency. Later, as time permits, more features can be added.

![doc/ggenc_prelim_arch.png](doc/ggenc_prelim_arch.png "Architecture Diagram" )

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

With most all warnings resolved and passing bringup sims, the gg_process module black box synthesis took under 20 minutes and resulted in:

30586 Luts, and 48 DSP. Of course 384 FFs are needed for above/left/dc state.











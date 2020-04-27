# gg264_enc
Open source verilog for a FPGA hardware H.264 Video Encoder.

(FPGA = Field Programmable Gate Array)

## Purpose

Create a running encoder as a platform to showcase FPGA optimizations in areas of low latency, high throuput, and HLS synthesis.

Provide an example design of a minimum viable H.264 hardware real-time video encoder with rate-control. 

Highlight the MPEG WebVC 'royalty free' video standard, "ISO/IEC 14496 Part 29: Web video coding"
- as it is compatible with all deployed H.264 AVC decoders, 
- to help gain some support for completing the 'royalty free' part of the standards effort.

## Platform
Use AWS cloud fpgas, with their immense EC2 f1.2xlarge fpga instances available on-demand. 
The runtime cost of $1.65/hr is affordable for hobbyist development. The 'F1 provides an available uniform platform for both open source hardware experimentation and scale deployment.
FPGA development tools are available at $0 additional cost, provided as an AMI to when creating new EC2 instances.

### EC2 Instances Emmployed
f1.2xlarge - $1.65/hr - FPGA runtime instance
r5.xlarge - $0.25/hr - Full chip FPGA synthesis 
r5.large - - $0.12/hr - Interactive block level synthesis sessions for $1/day

## Specifications

See my talk on WebVC and Open source hardware [talk](doc/webvc_talk_jan2020.pdf]
for my intitial thoughts.

Since then I've been reducing the minimum hardware feature set for a first working version, 
where the video encoder can be run at realtime to measure performance and latency.

I believe that minimal hardware is centered around a fully featured transform block encoder.


## Planning
follow a process spiral of: plan, model, design, synthesis, simulate

### Model
The C model can encode 720p video frames from a YUV files and output a valid bitstreams.
A known good decoder can be used to validate the output stream and match reconstructed data.
 
It is sufficient, for now, to provides a means to functionally bring up the transform block processing core.
(full verification is something else, and requires effort and rigor to acheive)

### Design
In progress: Design and RTL for the transform block rate-distortion process module. Written in System Verilog with syntax checking provided in Vivado IDE.






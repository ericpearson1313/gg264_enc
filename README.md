# gg264_enc
Open source verilog for a FPGA hardware H.264 Video Encoder.

(FPGA = Field Programmable Gate Array)

## Purpose

Create a running encoder as a platform to showcase FPGA optimizations in areas of low latency and high throuput.

Provide an example design of a minimum viable H.264 hardware real-time video encoder with rate-control. 

Highlight the MPEG WebVC 'royalty free' video standard, "ISO/IEC 14496 Part 29: Web video coding"
- as it is compatible with all deployed H.264 AVC decoders, 
- to help gain some support for completing the 'royalty free' part of the standards effort.

## Platform
Use AWS cloud fpgas, with their huge EC2 f1.2xlarge fpga compute instances. 
The runtime cost of $1.65/hr is alot cheaper than buying a development board and
it provides a widely available uniform platform for open source hardware experimentation.
FPGA development tools are available at $0 additional cost as an AMI for use on EC2 instances.

### EC2 Instances Emmployed
f1.2xlarge - $1.65/hr - FPGA runtime instance
r5.xlarge - $0.25/hr - Full chip FPGA synthesis 
r5.large - - $0.12/hr - Interactive block level synthesis.

## Specifications
TBD

## Model
The C model can encode video from a YUV files and output a valid bitstreams.
A known good decoder can be used to validate the output stream and match reconstructed data.
 
It is sufficient, for now, to provides a means to functionally bring up the transform block processing core.
(full verification is something else, and requires effort and rigor to acheive)

## Planning

Achieved
- C model of gg_process core with encoder wrapper
- Test C model against a video decoder and check for mis-match

In Progress
- write gg_process RTL, functional completeness, syntactically correct.

Planned
- itterative synthesis checks
- testbench wrapper, functional simulation (based on model extracted vectors)


# gg264_enc
Open source verilog for a FPGA hardware H.264 Video Encoder

## Purpose
Provide an example design of a minimum viable H.264 hardware real-time video encoder with rate-control. 
Highlight the MPEG WebVC 'royalty free' video standard, "ISO/IEC 14496 Part 29: Web video coding"
- it compatible with all H.264 AVC decoders, 
- to help gain some support for Mpeg completing the 'royalty free' effort.
A platform to test and highligh fpga optimization strategies for
- extremely low latency 
- extremely high throuput

## Platform
Use AWS cloud fpgas, with their ec2-f1: 2xlarge instance. The runtime cost of $1.65/hr is alot cheaper than buying a development board. 
It provides a widely available uniform platform for open source hardware experimentation.

## Specifications
TBD

## Model
- A basic C model is available, which provides a means to verify the transform block processing core.




# Stage 5: Substation L2 Pivot and Bay Controller Control

## Description


You have reached the station-side field network, but the most sensitive part of the substation is still separated from you.

The target environment contains a **substation gateway** that sits between two different network zones:

- the **Station Zone**, where engineering systems and automation services are reachable over TCP/IP
- the **Process Zone**, where low-level control traffic is exchanged directly over Layer 2 Ethernet

The Process Zone is closer to the physical switching equipment. It does not behave like a normal routed IP network. Traffic such as GOOSE-style control messages is transmitted at Layer 2 and cannot be sent directly from the Engineering Workstation or normal station-side hosts.

Your objective is to compromise the substation gateway, prove that it has access to the Process Zone, and then use that position to influence the bay controller.

The bay controller exposes two separate control paths:

1. A modern automation service that exposes operational values such as configuration revision and breaker state.
2. A legacy scripting interface that accepts SCIL-style control scripts.


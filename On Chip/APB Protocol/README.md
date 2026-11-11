  Advanced Peripheral Bus (APB) Protocol Explained

  The APB (Advanced Peripheral Bus) protocol is part of the ARM AMBA (Advanced Microcontroller Bus Architecture) family. It is specifically designed for
  connecting to low-bandwidth, low-power, and low-complexity peripherals (such as I2C, UART, SPI, GPIOs, and Timers) where high throughput and pipelined
  operations are unnecessary.
  ──────
  ## 1. Where Does APB Fit in a System-on-Chip (SoC)?

  In modern SoCs, buses are arranged in a hierarchy based on speed:

    +------------------------------------------------------+
    |            High-Performance Processor / DMA           |
    +------------------------------------------------------+
                               │ (AXI / AHB: High speed, pipelined, burst)
                               ▼
                      +------------------+
                      |    AXI/AHB to    |
                      |    APB Bridge    |
                      +------------------+
                               │ (APB: Simple, non-pipelined, low power)
              ┌────────────────┼────────────────┐
              ▼                ▼                ▼
         +---------+      +---------+      +---------+
         |   I2C   |      |  UART   |      |  Timer  |
         +---------+      +---------+      +---------+

  • AXI / AHB: Built for heavy traffic (CPUs, DDR controllers, DMAs) with bursts, split transactions, and out-of-order execution.
  • APB: Built for lightweight control registers. It does not support bursting or pipelining, making peripheral interfaces small in gate count and easy to
  design and test.
  ──────
  ## 2. Key Characteristics of APB

  1. Synchronous: All transfers occur on the rising edge of the bus clock (PCLK).
  2. Non-Pipelined: Only one transaction takes place at any given time.
  3. Minimum 2 Clock Cycles per Transfer:
      • Phase 1: SETUP cycle (select the peripheral and present the address/control).
      • Phase 2: ACCESS cycle (enable the data phase and complete the transfer).
  4. Low Power: Unselected peripherals stay idle; signal switching is minimized.
  ──────
  ## 3. Essential APB Signals

| Signal | Direction | Description | Introduced In |
|:---    |:---       |:---         |:---:          |
| `PCLK` | Bridge → Slave | Clock signal. All signals are sampled on the rising edge. | APB2 |
| `PRESETn` | Bridge → Slave | Active-LOW asynchronous reset. | APB2 |
| `PADDR` | Bridge → Slave | Address bus (typically up to 32 bits). | APB2 |
| `PSELx` | Bridge → Slave | Peripheral select line. Each slave has its own dedicated PSEL line. | APB2 |
| `PENABLE` | Bridge → Slave | Strobe signal indicating the ACCESS phase (2nd cycle onwards). | APB2 |
| `PWRITE` | Bridge → Slave | Transfer direction: 1 = Write, 0 = Read. | APB2 |
| `PWDATA` | Bridge → Slave | Write data bus (typically 8, 16, or 32 bits). | APB2 |
| `PRDATA` | Slave → Bridge | Read data bus. Driven by slave during read transfers. | APB2 |
| `PREADY` | Slave → Bridge | Handshake signal. Slave pulls LOW to insert wait states (stall). | APB3 |
| `PSLVERR` | Slave → Bridge | Transfer error indicator (e.g., invalid address or permission failure). | APB3 |
| `PSTRB` | Bridge → Slave | Byte strobes indicating valid byte lanes in write data (sparse writes). | APB4 |
| `PPROT` | Bridge → Slave | Protection attributes (Privileged, Secure, Data/Instruction). | APB4 |
  ──────
  ## 4. The APB Finite State Machine (FSM)

  The protocol operates using three primary states:

                +--------------+
                |     IDLE     | <-------------------------+
                +--------------+                           |
                       |                                   |
                       | Transfer requested                | Transfer completes
                       | (PSEL = 1, PENABLE = 0)           | (PREADY = 1)
                       v                                   | and no new transfer
                +--------------+                           |
                |    SETUP     |                           |
                +--------------+                           |
                       |                                   |
                       | Next clock cycle                  |
                       | (PENABLE = 1)                     |
                       v                                   |
                +--------------+                           |
       +------> |    ACCESS    | --------------------------+
       |        +--------------+
       | (PREADY = 0)  |
       +---------------+ (Slave not ready: extend ACCESS state)

  1. IDLE:
      • Default bus state.
      • PSEL = 0, PENABLE = 0.
  2. SETUP:
      • Entered when a transfer is needed.
      • Master drives PADDR, PWRITE, PWDATA (if write), and asserts PSEL = 1.
      • PENABLE remains 0.
      • Lasts exactly one clock cycle.
  3. ACCESS:
      • Master asserts PENABLE = 1.
      • Address, write data, and control signals must remain stable.
      • The transfer finishes when PREADY = 1.
      • If PREADY = 0, the bus remains in the ACCESS state (adding wait cycles).

"""Telnet-IAC framing for the panel console link.

The panel speaks a 3-byte ``FF FF FF`` terminated protocol. Some ser2net
configs run that link over telnet, which escapes every ``0xFF`` (IAC) as
``FF FF`` on the wire; other configs are raw (no escaping). These helpers
implement both framings so a single tool works with either ser2net setup.

Raw (default, ``iac=False``): bytes pass through untouched.
IAC (``--iac``): :func:`encode` doubles every ``0xFF`` before send;
:class:`IacDecoder` collapses the doubled pairs (and drops stray IAC
command bytes) on receive.
"""

# Telnet command bytes (RFC 854):  SE=0xF0 EC=0xEF SB=0xFA WILL=0xFB
# WONT=0xFC DO=0xFD DONT=0xFE IAC=0xFF
IAC = 0xFF
SE, EC, SB, WILL, WONT, DO, DONT = 0xF0, 0xEF, 0xFA, 0xFB, 0xFC, 0xFD, 0xFE

# How to answer each negotiation command: accept every option ser2net offers.
# WILL x -> DO x ; DO x -> WILL x ; WONT x -> DONT x ; DONT x -> WONT x
_ACCEPT = {WILL: DO, DO: WILL, WONT: DONT, DONT: WONT}


def negotiate(burst: bytes) -> bytes:
    """Build the accept-all reply to a telnet negotiation burst.

    ser2net (telnet mode) sends WILL/DO/DONT options on connect and, if the
    client never answers, holds all client data for its ~3 s negotiation
    timeout before forwarding it. Answering every option (accept) makes it
    start forwarding in ~10 ms. Returns the reply bytes (empty if the burst
    had no options).
    """
    out = bytearray()
    i, n = 0, len(burst)
    while i < n:
        if burst[i] == IAC and i + 2 < n:
            cmd, opt = burst[i + 1], burst[i + 2]
            if cmd in _ACCEPT:
                out += bytes([IAC, _ACCEPT[cmd], opt])
            i += 3
        else:
            i += 1
    return bytes(out)


def encode(data: bytes, iac: bool) -> bytes:
    """Escape ``0xFF`` as ``FF FF`` for a telnet wire (no-op when ``iac`` is false)."""
    if not iac:
        return data
    out = bytearray()
    for b in data:
        if b == IAC:
            out += b"\xff\xff"
        else:
            out.append(b)
    return bytes(out)


class IacDecoder:
    """Streaming IAC decoder: feed raw wire bytes, get decoded bytes back.

    Carries an in-progress IAC across :meth:`feed` boundaries, so a ``FF FF``
    pair split over two reads still collapses to one literal ``0xFF``. An
    ``FF`` followed by a non-``FF`` byte is a telnet command (negotiation) and
    is dropped.
    """

    def __init__(self):
        self.reset()

    def reset(self):
        self._pending = False      # saw IAC; next byte is a command / SB / IAC
        self._in_sub = False       # inside an IAC SB ... IAC SE subnegotiation
        self._sub_pend = False     # saw IAC inside a sub; next byte may be SE

    def feed(self, data: bytes) -> bytes:
        out = bytearray()
        for b in data:
            if self._in_sub:
                # Drop subnegotiation payload until IAC SE closes it.
                if self._sub_pend:
                    self._sub_pend = False
                    if b == SE:
                        self._in_sub = False
                elif b == IAC:
                    self._sub_pend = True
                continue
            if self._pending:
                self._pending = False
                if b == IAC:
                    out.append(IAC)      # IAC IAC -> one literal 0xFF
                elif b == SB:
                    self._in_sub = True  # IAC SB -> enter subnegotiation
                # else a negotiation command (WILL/WONT/DO/DONT/SE/EC) -> drop
                continue
            if b == IAC:
                self._pending = True
            else:
                out.append(b)
        return bytes(out)


class IacSerial:
    """Wraps a pyserial-like object, applying IAC escaping on write and un-escaping on read.

    Use it as a drop-in for the serial object so no call site changes: when
    ``iac`` is false it is a transparent pass-through.
    """

    def __init__(self, ser, iac: bool):
        self.ser = ser
        self.iac = iac
        self._dec = IacDecoder()

    def write(self, data) -> int:
        return self.ser.write(encode(data, self.iac))

    def read(self, n: int) -> bytes:
        raw = self.ser.read(n)
        return self._dec.feed(raw) if self.iac else raw

    def flush(self):
        return self.ser.flush()

    def reset_input_buffer(self):
        self.ser.reset_input_buffer()
        self._dec.reset()

    def handshake(self):
        """Complete the telnet negotiation with a ser2net telnet port.

        Reads the server's initial negotiation burst (``negotiate`` answers it by
        accepting every option) so ser2net stops waiting and starts forwarding.
        Without this reply ser2net holds all client data for its ~3 s negotiation
        timeout before forwarding it -- that stall was the entire console-open
        latency; with it, the first reply arrives in ~10 ms. No-op when
        ``iac`` is false (raw link has no negotiation).
        """
        if not self.iac:
            return
        import time
        raw = self.ser            # pyserial object: .read returns raw wire bytes
        burst = b""
        t0 = time.time()
        while time.time() - t0 < 0.1:  # the burst lands in ~1 ms; 0.1 s is ample margin
            c = raw.read(4096)
            if c:
                burst += c
        reply = negotiate(burst)
        if reply:
            raw.write(reply)
            raw.flush()
        self.reset_input_buffer()  # the burst is consumed; clear decoder state

    def close(self):
        return self.ser.close()

    @property
    def baudrate(self):
        return self.ser.baudrate

    @baudrate.setter
    def baudrate(self, value):
        self.ser.baudrate = value

    @property
    def timeout(self):
        return self.ser.timeout

    @timeout.setter
    def timeout(self, value):
        self.ser.timeout = value

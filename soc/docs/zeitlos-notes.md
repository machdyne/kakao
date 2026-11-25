# Notes for Zeitlos

Things found in Zeitlos (`ext/zeitlos`, pinned and not changed here)
while working on the Kakao SOC, for whoever changes it there.

## A mouse's report descriptor is parsed to the length asked for

`sw/apps/usb/usbh.c`, `case E_HID_RDESC`: the driver asks for as many
bytes of a mouse's report descriptor as the HID descriptor promises,
and then parses that many:

```c
int n = dv->ctrl_len > 400 ? 400 : dv->ctrl_len;
...
if (z_usbh_hid_rdesc_parse(d, n, &dv->mlay)) {
```

A device that sends fewer (a short packet ends the data stage) leaves
the rest of the scratch buffer as it was, and the parser reads it as
more of the descriptor: whatever an earlier transfer left there. It
comes to an end either way, but stale items after the real ones can
change the layout it finds, and so which protocol the mouse is put
into.

`dv->ctrl_xferred` is what arrived:

```c
int n = dv->ctrl_xferred > 400 ? 400 : dv->ctrl_xferred;
```

The same holds for `E_DIG_RDESC` (`dig_parse_at(d, dv->ctrl_len)`).

How it was found: in simulation the packet buffer starts as unknown
values, Zeitlos's model of a mouse sends 18 bytes where 52 are
promised, and the I/O processor's model stopped on the unknown bytes,
when no earlier packet had happened to fill that part of the buffer
(`sim/tb_iop_usb.v`, `make usb-late`). On a board the buffer is block
RAM and starts as zeros.

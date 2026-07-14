# Third-Party Acknowledgements

- **exelban/stats** (MIT): portions of the SMC interface structure
  (`SMCParamStruct` definition and approach) were derived and learned from the
  reference implementation within the [Stats](https://github.com/exelban/stats)
  open-source application.
- **charlie0129/batt** (GPL-3.0): the semantics of the Apple Silicon
  firmware charge-band SMC keys (`bfF0`/`bfD0`/`bfE0` — activation, upper,
  lower; little-endian percent encoding; strict write order) and the
  adapter/gate keys (`CHIE`, `CHTE`, `CH0B`/`CH0C`) were learned from
  [batt](https://github.com/charlie0129/batt)'s source and issue tracker as a
  research reference. **No code was copied** — Rebes' implementation is
  original Swift.
- **actuallymentor/battery** (MIT): additional key-semantics reference for
  adapter-disable behavior.
- **AlDente** (AppHouseKitchen): feature-set inspiration for the charge-control
  UX (limit, sailing, top-up, heat protection, calibration). No code or assets
  used.

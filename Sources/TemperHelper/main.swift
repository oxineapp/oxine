import TemperHelperCore
import TemperShared

// Oxine's privileged fan-control daemon. All the logic lives in TemperHelperCore;
// this entry point only picks the brand. A standalone Temper app would build the
// same core with its own `TemperHelperBranding`.
runTemperHelper(.oxine)

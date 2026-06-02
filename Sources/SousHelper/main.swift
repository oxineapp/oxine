import SousHelperCore
import SousShared

// Oxine's privileged battery-control daemon. All the logic lives in
// SousHelperCore; this entry point only picks the brand. The standalone
// sous-vide app builds the same core with its own `HelperBranding`.
runSousHelper(.oxine)

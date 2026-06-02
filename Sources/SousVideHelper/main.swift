import SousHelperCore
import SousShared

// The standalone sous-vide app's privileged battery-control daemon. Same engine
// as Oxine's (SousHelperCore), its own brand so the two daemons coexist.
runSousHelper(.sousVide)

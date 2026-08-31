GestureKit imports Config.swift, Actions.swift, GestureEngine.swift, Multitouch.swift
and the configuration menu from https://github.com/Sha-Dox/FnGestures at the commit
recorded in UPSTREAM_COMMIT, at the owner's request. Upstream does not include a
license file. Attribution is retained here; no third-party license is asserted.

Oxine integration replaces the standalone app lifecycle, launch agent and external
MiddleClick restart workaround with an embedded service/shared touch callback.
It adds middle-click settings, tap validation, paired click suppression, callback
cleanup, permission recovery, null zero-contact handling, stable touch ordering,
and a continuous-scroll lock fix. The original user's config is left untouched.

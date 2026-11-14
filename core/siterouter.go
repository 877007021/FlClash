package core

import (
	"github.com/metacubex/mihomo/component/siterouter"
)

type SiteOverridesParams struct {
	Overrides map[string]string `json:"overrides"`
}

// The host owns the per-site learning; it pushes the whole table whenever a
// site's ranking changes or a core start empties it. An empty map clears.
func handleSetSiteOverrides(params SiteOverridesParams) error {
	siterouter.Set(params.Overrides)
	return nil
}

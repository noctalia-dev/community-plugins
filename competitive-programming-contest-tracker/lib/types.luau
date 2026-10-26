--!nonstrict
export type Contest = {
  src: string,
  name: string,
  start: number,
  dur: number,
  url: string,
}
export type Platform = { id: string, name: string, icon: string }

export type Range = { id: string, labelKey: string, secs: number? }

export type Filters = {
  platforms: { [string]: boolean },
  range: string,
  favoritesOnly: boolean,
  favorites: { [string]: boolean },
  savedOnly: boolean,
  saved: { [string]: Contest },
}

export type BySource = { [string]: { Contest } }

export type Done = (up: { Contest }?, past: { Contest }?) -> ()

export type FetchOpts = { pastWindowSeconds: number }

export type Source = { id: string, fetch: (done: Done, opts: FetchOpts) -> () }

export type Tab = "upcoming" | "previous"

export type Variant = "default" | "destructive" | "ghost" | "outline" | "primary" | "secondary"

export type View = { tab: Tab, hoveredUrl: string? }

export type Ctx = {
  filters: Filters,
  view: View,
  rerender: () -> (),
  openUrl: (url: string) -> (),
  setFilters: () -> (),
  toggleFavorite: (url: string) -> (),
  toggleSaved: (c: Contest) -> (),
}

return {}

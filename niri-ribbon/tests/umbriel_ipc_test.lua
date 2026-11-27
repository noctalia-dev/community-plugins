-- Run from repository root: lua niri-ribbon/tests/umbriel_ipc_test.lua
local function near(a,b) assert(math.abs(a-b)<1e-9, tostring(a)..' ~= '..tostring(b)) end
local now, event, queries, publishes = 0, nil, 0, 0
local state, watches, widgets = {}, {}, {}
local data = {
 outputs = {
  {name='DP', enabled=true, position={x=-200}, logical_size={width=200}},
  {name='HDMI', enabled=true, position={x=0}, logical_size={width=300}},
 },
 workspaces = {
  {id='DP:1',output='DP',active=true,focused=true,focused_window='b',layout='scrolling'},
  {id='DP:2',output='DP',active=false,focused=false,focused_window='',layout='master'},
  {id='HDMI:1',output='HDMI',active=true,focused=false,focused_window='z',layout='master'},
 },
 windows = {
  {id='a',workspace='DP:1',column=0,x=-300,w=100},
  {id='b',workspace='DP:1',column=1,x=-190,w=100},
  {id='c',workspace='DP:1',column=2,x=-80,w=200,visible=false},
  {id='tab',workspace='DP:1',column=1,x=-190,w=100,tab_hidden=true},
  {id='z',workspace='HDMI:1',column=-1,x=0,w=300},
 },
}
for _,flag in ipairs({'floating','pinned','minimized','scratchpad'}) do
 local win={id=flag,workspace='DP:1',column=4,x=-10000,w=10000}
 win[flag]=flag=='scratchpad' and 'stash' or true
 table.insert(data.windows,win)
end
local service=setmetatable({noctalia={
 getenv=function(key) return ({XDG_CURRENT_DESKTOP='Umbriel',NIRI_SOCKET='stale'})[key] end,
 commandExists=function() return true end,
 nowMs=function() return now end, setUpdateInterval=function() end,
 json={decode=function(value) return value end},
 runStream=function(cmd,cb) assert(cmd:find('umbriel subscribe windows,workspaces,outputs',1,true));event=cb;return true end,
 runAsync=function(cmd,cb)
  queries=queries+1
  local key=cmd:match('^umbriel (%w+) %-%-json$');assert(key,cmd)
  cb({exitCode=0,stdout=data[key]});return true
 end,
 state={set=function(key,value)
  publishes=publishes+1;state[key]=value
  for _,cb in ipairs(watches[key] or {}) do cb(value) end
 end},
}}, {__index=_G})
assert(loadfile('niri-ribbon/service.luau','t',service))()
local function flush() now=now+33;service.update() end
flush()
local function widget(output,hide)
 local result={visible=true,actions={}}
 local env=setmetatable({noctalia={
  getConfig=function(key) return ({animation_speed=0,show_active_window=true,hide_non_scrolling=hide,gaps=999})[key] end,
  setUpdateInterval=function() end,
  runAsync=function(cmd) table.insert(result.actions,cmd) end,
  state={get=function(key) return state[key] end,watch=function(key,cb)
   watches[key]=watches[key] or {};table.insert(watches[key],cb)
  end},
 },ui={box=function(p) return p end,row=function(p,c) p.children=c;return p end},
 barWidget={outputName=function() return output end,render=function(tree) result.tree=tree end,
 setVisible=function(visible) result.visible=visible end}}, {__index=_G})
 assert(loadfile('niri-ribbon/ribbon.luau','t',env))();result.env=env;return result
end
local dp,hdmi,always=widget('DP',true),widget('HDMI',true),widget('HDMI',false)
assert(state['output:DP'].backend=='umbriel')
assert(#state['output:DP'].windows==4)
near(dp.tree.children[1].width,80*100/420)
near(dp.tree.children[2].width,80*200/420)
near(dp.tree.children[2].children[2].width,80*100/420)
assert(dp.visible and not hdmi.visible and always.visible)
near(always.tree.children[2].width,80)
near(always.tree.children[2].children[2].width,0)
dp.env.onScroll('vertical',-1,true);dp.env.onScroll('vertical',1,true)
assert(dp.actions[1]=='umbriel msg window-focus-left' and dp.actions[2]=='umbriel msg window-focus-right')
hdmi.env.onScroll('vertical',1,true);always.env.onScroll('vertical',1,true)
assert(#hdmi.actions==0 and #always.actions==0)
local before=publishes
data.windows[1].title='irrelevant';data.windows[1].y=900
event({event='windows',data=data.windows});flush();assert(publishes==before)
-- Full replacement positions reflect scrolling without focus changes.
for _,win in ipairs(data.windows) do win.x=win.x-20 end
event({event='windows',data=data.windows});flush()
near(dp.tree.children[1].width,80*120/420)
-- Workspace layout changes hide/show independently on each output.
data.workspaces[1].layout='dwindle'
event({event='workspaces',data=data.workspaces});flush();assert(not dp.visible)
data.workspaces[1].layout='scrolling'
event({event='workspaces',data=data.workspaces});flush();assert(dp.visible and not hdmi.visible)
near(dp.tree.children[1].width,80*120/420)
-- Switch to another workspace and back on the same output.
data.workspaces[1].active=false;data.workspaces[2].active=true
event({event='workspaces',data=data.workspaces});flush();assert(not dp.visible)
data.workspaces[1].active=true;data.workspaces[2].active=false
event({event='workspaces',data=data.workspaces});flush();assert(dp.visible)
-- Empty snapshots remove old windows; no stale marker.
event({event='windows',data={}});flush()
near(dp.tree.children[2].width,80);near(dp.tree.children[2].children[2].width,0)
assert(queries==3)
print('PASS: Umbriel detection, global geometry, multiple monitors/workspaces, tabs, exclusions, layout visibility, scrolling, event filtering')

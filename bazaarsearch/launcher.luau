--!strict

-- ================================== --
-- ===== API STRINGS DEFINITION ===== --
-- ================================== --
local BZR_DBUS_BUSNAME: string = "io.github.kolunmi.Bazaar.SearchProvider"
local BZR_DBUS_OBJ_PATH: string = "/io/github/kolunmi/Bazaar/SearchProvider"
local BZR_DBUS_INTERFACE: string = "org.gnome.Shell.SearchProvider2"


-- ============================= --
-- ====== TYPES DEFINITION ===== --
-- ============================= --

-- Type definition for bzrCreateErrorReport param type
type BzrErrReport = {
  cmd_string: string?,  -- The command run before this error
  stage: string?,       -- The function this error was called from
  query: string,        -- The query string the user input. Required.
  err_title: string,    -- The title this error should display. Required.
  err_body: string?,    -- The subtitle (body) this error should display.
}

-- -- Type definition for the return value of bzrInitialSearch()
type BzrInitialSearchReturn = {
  entries_string: string, -- The string generated for the command in bzrGetMetadata()
  num_elem: number,       -- The number of elements inside of `entries_string`
}


-- ================================= --
-- ===== APPLICATION FUNCTIONS ===== --
-- ================================= --


-- Wrapper for noctalia translate function
local function bzrTR(key: string, replaces: {[string]: boolean | number | string}?): string
  return noctalia.tr(key, replaces)
end

-- Input sanitization function for Flatpak IDs
-- As per Flatpak (https://docs.flatpak.org/en/latest/conventions.html)
-- and the DBus naming convention (https://dbus.freedesktop.org/doc/dbus-specification.html#message-protocol-names),
-- the only allowed characters in Flatpak IDs are "[a-z][A-Z][0-9]_-."
--
-- Returns the sanitized string
local function bzrFlatpakIDSanitize(s: string): string
  local retval, _ = s:gsub("[^a-zA-Z0-9_%-%.]", "")
  return retval
end


-- Input sanitization function for user input (shell scripts)
-- As per the Open Group Base Spec (https://pubs.opengroup.org/onlinepubs/9799919799/)
-- definition of POSIX double quoting, the characters that retain special
-- functionality are the quote, backslash, backquote, and dollar sign.
-- This method simply removes all instances of these characters, as they
-- generally shouldn't be needed for general purpose searches.
--
-- Returns the sanitized string
local function bzrUserInputSanitize(s: string): string
  local retval, _ = s:gsub("[%$`\"\\\\]", "")
  return retval
end


-- Helper function to generate an error entry in the case
-- that something goes wrong
--
-- Returns a table row that the launcher will put as an
-- entry.
local function bzrCreateErrorReport(data: BzrErrReport): LauncherResult
  local cmd_string = data["cmd_string"] and tostring(data["cmd_string"]) or bzrTR("error.no_cmd_prov")
  local stage = data["stage"] and tostring(data["stage"]) or bzrTR("error.no_stage_prov")
  local query = data["query"]
  local err_title = data["err_title"]
  local err_body = data["err_body"] and tostring(data["err_body"]) or ""

  local full_err_msg = string.format("%s\n", bzrTR("error.report.header"))
                    .. string.format("%s: %s\n", bzrTR("error.report.stage"), stage)
                    .. string.format("%s: %s\n", bzrTR("error.report.command"), cmd_string)
                    .. string.format("%s: %s\n", bzrTR("error.report.query"), query)
                    .. string.format("%s: %s\n%s", bzrTR("error.report.error"), err_title, err_body)


  return {
    id = "bzrerror:" .. full_err_msg,
    title = err_title,
    subtitle = bzrTR("error.report.user_instruction"),
    glpyh = "toast-error"
  }
end

-- Takes in the item IDs from the iniial bazaar search, then
-- gets metadata and adds them into rows
--
-- Returns rows generated, or an optional error row in the
-- case of problems arising.
local function bzrGetMetadata(query: string, bzr_search_data: BzrInitialSearchReturn)
  
  -- Construct our second command, this time getting metadata
  -- from the GetResultMetas DBus function
  
  local cmd_string = "busctl --user --json=short "
                  .. "call " .. BZR_DBUS_BUSNAME .. " "
                  .. BZR_DBUS_OBJ_PATH .. " "
                  .. BZR_DBUS_INTERFACE .. " "
                  .. "GetResultMetas "
                  .. bzr_search_data.entries_string

  noctalia.runAsync(cmd_string,
    function(result)

      if result.exitCode ~= 0 then
        -- busctl failed, print stderr so we can see why
        launcher.setResults(query, {bzrCreateErrorReport({
          cmd_string = cmd_string,
          stage = "getMetadata",
          query = query,
          err_title = bzrTR("error.msg.busctl_fail", { exitCode = result.exitCode }),
          err_body = result.stderr
        })})
        return 
      end

      -- Get Tabular version of data thanks to JSON parsing
      local busdata, err = noctalia.json.decode(result.stdout)
      if not busdata then
        return launcher.setResults(query, {bzrCreateErrorReport({
          cmd_string = cmd_string,
          stage = "getMetadata",
          err_title = bzrTR("error.msg.busctl_json_fail"),
          err_body = err,
          query = query,
        })})
      end

      -- Double check the parameter type
      if busdata["type"] ~= "aa{sv}" then
        return launcher.setResults(query, {bzrCreateErrorReport({
          cmd_string = cmd_string,
          stage = "getMetadata",
          query = query,
          err_title = bzrTR("err.msg.malformed_value_retval"),
          err_body = bzrTR("error.msg.busctl_incorrect_ident", { expected = "aa{sv}", recieved = busdata["type"] }),
        })})
      end

      
      -- Iterate through table, creating row descriptions based
      -- on the given metadata
      
      local rows = {}
      -- The [1] at the end is because we only care about
      -- one single query, which is the one we're making.
      -- This interface technically lets us search a whole
      -- bunch of things if we want to
      local entry_data = busdata["data"][1]
      for i = 1, #entry_data do
        local sanitized_fpkid = bzrFlatpakIDSanitize(entry_data[i]["id"]["data"])
        if sanitized_fpkid == entry_data[i]["id"]["data"] then
          table.insert(rows, {
            id = sanitized_fpkid,
            title = entry_data[i]["name"]["data"],
            icon = entry_data[i]["gicon"] and entry_data[i]["gicon"]["data"] or "check",
            subtitle = entry_data[i]["description"] and entry_data[i]["description"]["data"] or "",
          })
        end
      end

      launcher.setResults(query, rows)
    end
  )
end


-- Takes in the search parameter, passes it to the DBus
-- search interface, and gets a list of things that match
--
-- Returns the data necessary for getMetadata and optionally
-- an error, if something went wrong.
local function bzrInitialSearch(query)
  local text = noctalia.string.trim(query)
  local cmd_string = "busctl "
                  .. "--user --json=short "
                  .. "call " .. BZR_DBUS_BUSNAME .. " "
                  .. BZR_DBUS_OBJ_PATH .. " "
                  .. BZR_DBUS_INTERFACE .. " "
                  .. "GetInitialResultSet "
                  .. "as 1 \"" .. bzrUserInputSanitize(text) .. "\""

  noctalia.runAsync(
    cmd_string,
    function(result)
      noctalia.log(tostring(result.exitCode))
      if result.exitCode ~= 0 then
        -- busctl failed, print stderr so we can see why
        return launcher.setResults(query, {bzrCreateErrorReport({
          cmd_string = cmd_string,
          stage = "initialBazaarSearch",
          query = query,
          err_title = bzrTR("error.msg.busctl_fail", { exitCode = result.exitCode }),
          err_body = result.stderr
        })})
      end

      -- Get Tabular version of data thanks to JSON parsing
      local busdata, err = noctalia.json.decode(result.stdout)
      if not busdata then
        return launcher.setResults(query, {bzrCreateErrorReport({
          cmd_string = cmd_string,
          stage = "initialBazaarSearch",
          err_title = bzrTR("error.msg.busctl_json_fail"),
          err_body = err,
          query = query,
        })})
      end

      -- Double check the parameter type
      if busdata["type"] ~= "as" then
        return launcher.setResults(query, {bzrCreateErrorReport({
          cmd_string = cmd_string,
          stage = "initialBazaarSearch",
          err_title = bzrTR("error.msg.malformed_value_retval"),
          err_body = bzrTR("error.msg.busctl_incorrect_ident", { expected = "as", recieved = busdata["type"] }),
          query = query,
        })})
      end

      local obtained_entries = busdata["data"][1]
      -- ### HERE IS WHERE WE MINIMIZE THE NUMBER OF ENTRIES WE PARSE ### --
      local n_elem_to_count = math.min(noctalia.getConfig("max_entries"), #obtained_entries)
      local actual_elem_added = 0
      local entries_string = ""
      for i = 1, n_elem_to_count do
        noctalia.log(obtained_entries[i])
        -- Sanitize Flatpak ID (just in case of malicious input)
        local sanitized_fpkid = bzrFlatpakIDSanitize(obtained_entries[i])
        -- If sanitized ID does not match given ID, skip this. We don't want
        -- any shenanigans happening.
        if sanitized_fpkid == obtained_entries[i] then
          entries_string = entries_string .. " \"" .. sanitized_fpkid .. "\""
          actual_elem_added = actual_elem_added + 1
        end
      end

      -- Craft the cmd input for stage 2
      entries_string = "as " .. tostring(actual_elem_added) .. entries_string

      -- Proceed to step 2 of getting entries
      bzrGetMetadata(query, { entries_string = entries_string, num_elem = actual_elem_added })
    end
  )
end

-- ================================================ --
-- ===== NOCTALIA LAUNCHER OVERRIDE FUNCTIONS ===== --
-- ================================================ --

-- onQuery is what we call when the search text changes
function onQuery(query)
  if not noctalia.commandExists("busctl") then
    -- No busctl command, display error
    launcher.setResults(query, {bzrCreateErrorReport({
      cmd_string = "noctalia.commandExists(\"busctl\")",
      query = query,
      stage = "onQuery",
      err_title = bzrTR("error.msg.busctl_not_found"),
      err_body = bzrTR("error.msg.busctl_not_found_body"),
    })})
    return
  end

  -- Otherwise, do Bazaar search
  bzrInitialSearch(query)
end

--onActivate is what is called when we press Enter on something
function onActivate(id: string)
  local errmsg = id:match("^bzrerror:(.+)$")
  if errmsg then
    noctalia.copyToClipboard(errmsg, "text/plain")
    noctalia.notify(
      bzrTR("error.notify.copy.title"),
      bzrTR("error.notify.copy.msg")
    )
    return
  end
  if id ~= "" then
    local sanitized_fltpk = bzrFlatpakIDSanitize(id)
    if sanitized_fltpk == id then
      noctalia.runAsync(
        "busctl --user "
        .. "call " .. BZR_DBUS_BUSNAME .. " "
        .. BZR_DBUS_OBJ_PATH .. " "
        .. BZR_DBUS_INTERFACE .. " "
        .. "ActivateResult "
        .. "sasu \"" .. id .. "\" 0 " .. tostring(os.time()) 
      )
    else
      noctalia.notifyError(
        bzrTR("error.notify.activate.title"),
        bzrTR("error_notify.activate.msg")
      )
    end
  end
end

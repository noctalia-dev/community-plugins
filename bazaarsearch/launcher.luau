--!strict

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

-- Type definition for the return value of bzrInitialSearch()
type BzrInitialSearchReturn = {
  entries_string: string, -- The string generated for the command in bzrGetMetadata()
  num_elem: number,       -- The number of elements inside of `entries_string`
}

-- Imitating Rust Result<> type via Lua

type BzrOk<T> = { ok: true, data: T }
type BzrErr<E> = { ok: false, err: E }
type BzrResult<T, E> = BzrOk<T> | BzrErr<E>

-- Instantiates a BzrOK table. For use with BzrResult
-- return types.
local function bzrMakeOk<T>(data: T): BzrOk<T>
  return { ok = true, data = data }
end

-- Instantiates a BzrErr table. For use with BzrResult
-- return types
local function bzrMakeErr<E>(err: E): BzrErr<E>
  return { ok = false, err = err }
end



-- ================================= --
-- ===== APPLICATION FUNCTIONS ===== --
-- ================================= --

-- General Application flow:
--
-- <User Input>
-- ├── Check for `busctl`. If it does not exist, bzrNotifyError(). Execution stops
-- │ initialBazaarSearch()
-- ├── On error: bzrNotifyError(). Execution Stops
-- │ bzrNotify( callback = getMetadata )
-- ├── If global query does not match passed in query, stop execution.
-- │ getMetadata()
-- ├── If global query does not match passed in query, stop execution.
-- ├── On other error: bzrNotifyError(). Execution stops
-- │ bzrNotify( callback = bzrFinishQuery )
-- ├── If global query does not match passed in query, stop execution.
-- │ Set results. Stop Execution



-- Input sanitization function for Flatpak IDs
-- As per Flatpak (https://docs.flatpak.org/en/latest/conventions.html)
-- and the DBus naming convention (https://dbus.freedesktop.org/doc/dbus-specification.html#message-protocol-names),
-- the only allowed characters in Flatpak IDs are "[a-z][A-Z][0-9]_-."
--
-- Returns the sanitized string
local function bzrFlatpakIDSanitize(s: string): string
  local retval, _ = s:gsub("[^[a-z][A-Z][0-9]_%-%.]", "")
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
  local cmd_string = data["cmd_string"] and tostring(data["cmd_string"]) or "no command provided"
  local stage = data["stage"] and tostring(data["stage"]) or "no stage provided"
  local query = data["query"] and tostring(data["query"]) or "no query provided"
  local err_title = data["err_title"] and tostring(data["err_title"]) or "no error title provided"
  local err_body = data["err_body"] and tostring(data["err_body"]) or ""

  local full_err_msg = "ERROR REPORT\n"
                    .. "Stage: " .. stage .. "\n"
                    .. "Command: " .. cmd_string .. "\n"
                    .. "Query: " .. query .. "\n"
                    .. "Error: " .. err_title .. "\n"
                    .. err_body


  return {
    id = "bzrerror:" .. full_err_msg,
    title = err_title,
    subtitle = "Select this to copy an error report for the maintainer.",
    glpyh = "toast-error"
  }
end

-- Takes in the item IDs from the iniial bazaar search, then
-- gets metadata and adds them into rows
--
-- Returns rows generated, or an optional error row in the
-- case of problems arising.
local function bzrGetMetadata(query: string, bzr_search_data: BzrInitialSearchReturn): BzrResult<{LauncherResult}, LauncherResult>
  
  -- Construct our second command, this time getting metadata
  -- from the GetResultMetas DBus function
  
  local cmd_string = "busctl --user --json=short "
                  .. "call io.github.kolunmi.Bazaar "
                  .. "/io/github/kolunmi/Bazaar/SearchProvider "
                  .. "org.gnome.Shell.SearchProvider2 "
                  .. "GetResultMetas "
                  .. bzr_search_data.entries_string

  noctalia.runAsync(cmd_string,
    function(result)

      if result.exitCode ~= 0 then
        -- busctl failed, print stderr so we can see why
        return bzrMakeErr(bzrCreateErrorReport({
          cmd_string = cmd_string,
          stage = "getMetadata",
          query = query,
          err_title = "'busctl' failed with exit code " .. tostring(result.exitCode),
          err_body = result.stderr
        }))
      end

      -- Get Tabular version of data thanks to JSON parsing
      local busdata, err = noctalia.json.decode(result.stdout)
      if not busdata then
        return bzrMakeErr(bzrCreateErrorReport({
          cmd_string = cmd_string,
          stage = "getMetadata",
          err_title = "Failed to parse 'busctl' JSON data",
          err_body = err,
          query = query,
        }))
      end

      -- Double check the parameter type
      if busdata["type"] ~= "aa{sv}" then
        return bzrMakeErr(bzrCreateErrorReport({
          cmd_string = cmd_string,
          stage = "getMetadata",
          query = query,
          err_title = "Search returned malformed value - 'busctl' return type identifier is incorrect",
          err_body = "Expected \"aa{sv}\", got \"" .. busdata["type"] .. "\"",
        }))
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

      return bzrMakeOk(rows)
    end
  )

  return bzrMakeErr(bzrCreateErrorReport({
    stage = "getMetadata",
    query = query,
    err_title = "Somehow got out of command execution",
  }))
end


-- Takes in the search parameter, passes it to the DBus
-- search interface, and gets a list of things that match
--
-- Returns the data necessary for getMetadata and optionally
-- an error, if something went wrong.
local function bzrInitialSearch(query): BzrResult<BzrInitialSearchReturn, LauncherResult>
  local text = noctalia.string.trim(query)
  local cmd_string = "busctl "
                  .. "--user --json=short "
                  .. "call "
                  .. "io.github.kolunmi.Bazaar "
                  .. "/io/github/kolunmi/Bazaar/SearchProvider "
                  .. "org.gnome.Shell.SearchProvider2 "
                  .. "GetInitialResultSet "
                  .. "as 1 \"" .. bzrUserInputSanitize(text) .. "\""

  noctalia.runAsync(
    cmd_string,
    function(result)
      if result.exitCode ~= 0 then
        -- busctl failed, print stderr so we can see why
        return bzrMakeErr(bzrCreateErrorReport({
          cmd_string = cmd_string,
          stage = "initialBazaarSearch",
          query = query,
          err_title = "'busctl' failed with exit code " .. tostring(result.exitCode),
          err_body = result.stderr
        }))
      end

      -- Get Tabular version of data thanks to JSON parsing
      local busdata, err = noctalia.json.decode(result.stdout)
      if not busdata then
        return bzrMakeErr(bzrCreateErrorReport({
          cmd_string = cmd_string,
          stage = "initialBazaarSearch",
          err_title = "Failed to parse 'busctl' JSON data",
          err_body = err,
          query = query,
        }))
      end

      -- Double check the parameter type
      if busdata["type"] ~= "as" then
        return bzrMakeErr(bzrCreateErrorReport({
          cmd_string = cmd_string,
          stage = "initialBazaarSearch",
          err_title = "Search returned malformed value - arraystring identifier is incorrect",
          err_body = "Expected \"as\", got \"" .. busdata["type"] .. "\"",
          query = query,
        }))
      end

      local obtained_entries = busdata["data"][1]
      -- ### HERE IS WHERE WE MINIMIZE THE NUMBER OF ENTRIES WE PARSE ### --
      local n_elem_to_count = math.min(noctalia.getConfig("max_entries"), #obtained_entries)
      local actual_elem_added = 0
      local entries_string = ""
      for i = 1, n_elem_to_count do
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
      return bzrMakeOk({ entries_string = entries_string, num_elem = actual_elem_added })
    end
  )

  return bzrMakeErr(bzrCreateErrorReport({
    stage = "initialBazaarSearch",
    query = query,
    err_title = "Somehow got out of command execution",
  }))
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
      err_title = "'busctl' is not found in the PATH",
      err_body = "Please make sure that 'busctl' is installed and is correctly set somewhere along the PATH",
    })})
    return
  end

  -- Test mode enabled, as well as typing in test phrase
  if noctalia.getConfig("testmode_enable") and query == ".dbg" then
    launcher.setResults(query, {{
      id = "test:test",
      title = "Testmode Active",
    }})
    return
  end

  -- Otherwise, do Bazaar search
  local result_step1: BzrResult<BzrInitialSearchReturn, LauncherResult> = bzrInitialSearch(query)
  if not result_step1.ok then
    -- something went wrong in first part, display said
    -- error to user
    launcher.setResults(query, { result_step1.err })
    return
  end

  -- Step 2 of Bazaar search
  local step1_entries: BzrInitialSearchReturn = result_step1.data
  local result_step2 = bzrGetMetadata(query, step1_entries)
  if not result_step2.ok then
    launcher.setResults(query, { result_step2.err} )
    return
  end

  -- Everything seems to have gone okay, so put results on screen
  local entries: {LauncherResult} = result_step2.data
  launcher.setResults(query, entries)
end

--onActivate is what is called when we press Enter on something
function onActivate(id: string)
  local errmsg = id:match("^bzrerror:(.+)$")
  if errmsg then
    noctalia.copyToClipboard(errmsg, "text/plain")
    noctalia.notify("Bazaar Search Error", "Error message copied to clipboard.")
    return
  end
  if id ~= "" then
    local sanitized_fltpk = bzrFlatpakIDSanitize(id)
    if sanitized_fltpk == id then
      noctalia.runAsync(
        "busctl --user "
        .. " call io.github.kolunmi.Bazaar "
        .. "/io/github/kolunmi/Bazaar/SearchProvider "
        .. "org.gnome.Shell.SearchProvider2 "
        .. "ActivateResult "
        .. "sasu \"" .. id .. "\" 0 " .. tostring(os.time()) 
      )
    else
      noctalia.notifyError("Bazaar Search Error", "Selected Flatpak ID failed sanitization check, ignoring launch command.")
    end
  end
end

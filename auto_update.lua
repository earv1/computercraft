--[[
    Simple ETag Check and Run Script

    Checks the ETag header of a remote file. If it has changed (or on first run),
    it downloads the file and then executes it using shell.run().

    *** IMPORTANT LIMITATION ***
    ---------------------------
    This script runs in a single thread. It CHECKS for updates, potentially DOWNLOADS,
    and only THEN runs the target script using 'shell.run()'.
    If the target script ('localFilename') runs for a long time or never exits,
    this script will be BLOCKED and CANNOT check for further updates until the
    target script finishes.

    This is only suitable for target scripts that perform a task and then exit.
--]]

local args = { ... } -- Capture command-line arguments
local localFilename = args[1] -- Get the first argument

-- // ======================== CONFIGURATION ======================== //
local config = {
    -- REQUIRED: URL pointing to the *RAW* content of your program file
    programUrl = "https://raw.githubusercontent.com/earv1/computercraft/refs/heads/main/scripts/"..localFilename,

    -- REQUIRED: The filename to save the program as locally
    localFilename = localFilename,

    -- How often to check for updates WHEN THE TARGET PROGRAM IS NOT RUNNING
    -- (e.g., between runs if the target program exits quickly). In seconds.
    checkInterval = 2
}
-- // =============================================================== //


-- // ======================== SCRIPT STATE ========================= //
local lastKnownETag = nil       -- Stores the last seen ETag HTTP header

-- // ======================== HELPER FUNCTIONS ===================== //
local function log(message)
    print("[ETagRunner] " .. os.date("%H:%M:%S", os.epoch("utc")) .. " " .. message)
end

local function logError(message)
    printError("[ETagRunner] ERROR: " .. os.date("%H:%M:%S", os.epoch("utc")) .. " " .. message)
end

local noCacheHeaders = {
    ["Cache-Control"] = "no-cache, no-store, must-revalidate", -- Standard HTTP/1.1 headers
    ["Pragma"] = "no-cache",                                -- For older HTTP/1.0 caches/proxies
    ["Expires"] = "0"                                       -- Another directive often used
}

function epochSeconds()
    return os.epoch("utc")/ 1000
end
-- Function to download and save the file (simplified, assumes overwrite needed)
-- Returns: table (response headers from download), or nil on failure
function downloadAndSave()
    log("Attempting download from " .. cacheEvictUrl(config.programUrl))
    local download_ok, handle_or_err = pcall(http.get, config.programUrl, noCacheHeaders, true)

    if not download_ok or not handle_or_err then
        logError("http.get failed: " .. tostring(handle_or_err or "Unknown HTTP error"))
        return nil
    end

    local responseHeaders = handle_or_err.getResponseHeaders()
    local newContent = handle_or_err.readAll()
    handle_or_err.close()

    if not newContent then
        logError("Failed to read content from HTTP response.")
        -- Still return headers if we got them, maybe ETag changed even if content failed
        return responseHeaders
    end

    log("Download successful (" .. #newContent .. " bytes). Saving to " .. config.localFilename)
    local write_ok, write_err = pcall(function()
        local file = fs.open(config.localFilename, "w")
        if file then file.write(newContent); file.close(); return true end
        error("Failed to open " .. config.localFilename .. " for writing.")
    end)

    if not write_ok then
        logError("Failed to save file: " .. tostring(write_err))
    else
        log("File saved successfully.")
    end
    -- Return headers whether save worked or not, so ETag state can be updated
    return responseHeaders
end
-- // =============================================================== //

function cacheEvictUrl(url)
    return url.."?t="..os.epoch("utc")
end

function getEtag()
    -- Make a PATCH request using the table syntax of http.get
    local handle, errorMsg = http.get({
        url = cacheEvictUrl(config.programUrl),
        method = "HEAD",
        headers = noCacheHeaders
    })
    
    if not handle then
        return nil, "Request failed: " .. (errorMsg or "unknown error")
    end
    
    -- Get the headers
    local headers = handle.getResponseHeaders()
    -- Close the handle
    handle.close()
    log("Etag: ".. headers["ETag"])
    -- Return just the ETag header
    return headers["ETag"]
end

-- // ======================== MAIN LOOP ============================ //
function outdated()
    local currentETag = nil
    log("Checking headers for updates...")
    local etag = getEtag()

    if not fs.exists(config.localFilename) then
        log("Local file '" .. config.localFilename .. "' missing.")
        return true
    end
    if etag == nil then
        log("http.request failed or unavailable")
        os.exit(1)
        return true
    end

    if etag and lastKnownETag and etag == lastKnownETag then
        log("ETag unchanged.")
        return false
    else
        lastKnownETag = etag
        return true
    end
end

function  runFile()
    if fs.exists(config.localFilename) then
        log("Executing target program: " .. config.localFilename .. "...")
        print("--- Target Program Output Starts ---")
        local ok, err = pcall(shell.run, config.localFilename) -- *** BLOCKS HERE ***
        print("--- Target Program Output Ends ---")
        if not ok then
            logError("Target program '" .. config.localFilename .. "' crashed: " .. tostring(err))
            log("Waiting 10s before next cycle...")
        end
    else
        logError("Target file '" .. config.localFilename .. "' does not exist. Cannot execute.")
    end

    -- 4. Wait before next check cycle
    log("Waiting for " .. config.checkInterval .. "s before next check...")
    log("--- Cycle Complete ---")
end


local lastCheckTimestamp = 0
while true do
    local currentTime = epochSeconds()
    local elapsedSinceLastCheck = currentTime - lastCheckTimestamp

    runFile()
    if elapsedSinceLastCheck > config.checkInterval then
        lastCheckTimestamp = epochSeconds()
    else
        log("Not enough time passed to check: "..elapsedSinceLastCheck)
        goto continue
    end

    if not outdated() then
        log("No download required.")
        goto continue
    end

    log("Update required or first run/file missing.")
    downloadAndSave() -- Attempt downloa

    -- 3. Execute the program (if it exists)
    ::continue:: -- Label marking the end of the iteration
    sleep(1)
end -- End of while true loop
-- // =============================================================== //
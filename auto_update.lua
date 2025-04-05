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
    programUrl = "https://raw.githubusercontent.com/earv1/computercraft/refs/heads/main/"..localFilename,

    -- REQUIRED: The filename to save the program as locally
    localFilename = localFilename,

    -- How often to check for updates WHEN THE TARGET PROGRAM IS NOT RUNNING
    -- (e.g., between runs if the target program exits quickly). In seconds.
    checkInterval = 60
}
-- // =============================================================== //


-- // ======================== SCRIPT STATE ========================= //
local lastKnownETag = nil       -- Stores the last seen ETag HTTP header
local lastCheckTimestamp = 0

-- // ======================== HELPER FUNCTIONS ===================== //
local function log(message)
    print("[ETagRunner] " .. os.date("%H:%M:%S", os.epoch("utc")) .. " " .. message)
end

local function logError(message)
    printError("[ETagRunner] ERROR: " .. os.date("%H:%M:%S", os.epoch("utc")) .. " " .. message)
end

-- Function to download and save the file (simplified, assumes overwrite needed)
-- Returns: table (response headers from download), or nil on failure
local function downloadAndSave()
    log("Attempting download from " .. config.programUrl)
    local download_ok, handle_or_err = pcall(http.get, config.programUrl, nil, true)

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


-- // ======================== MAIN LOOP ============================ //
log("Starting Simple ETag Check and Run Loop.")
log("Target URL: " .. config.programUrl)
log("Check Interval (when idle): " .. config.checkInterval .. "s")
print("---")

while true do
    local needsDownload = false
    local currentETag = nil
    local currentTime = os.time("utc") -- Use os.time for integer seconds, matches os.epoch better historically

    local elapsedSinceLastCheck = currentTime - lastCheckTimestamp

    if elapsedSinceLastCheck < config.checkInterval then
        local sleepDuration = config.checkInterval - elapsedSinceLastCheck
        -- Only log if sleep is significant to avoid spam
        if sleepDuration > 0.1 then
            log(string.format("Minimum interval (%ds) not met. Waiting for %.1f s...", config.minCheckIntervalSeconds, sleepDuration))
        end
        lastCheckTimestamp = os.time("utc")
    end


    -- 1. Check Headers using Lua http API
    log("Checking headers for updates...")
    local check_ok, handle_or_err = pcall(http.check, config.programUrl)
    if check_ok and handle_or_err then
        local headers = handle_or_err.getResponseHeaders()
        handle_or_err.close()
        currentETag = headers["ETag"]
        log("Received Headers - ETag: "..(currentETag or "N/A"))

        if currentETag and lastKnownETag and currentETag == lastKnownETag then
            log("ETag unchanged.")
            needsDownload = false
        else
            if currentETag then log("ETag changed or first check.") else log("ETag unavailable.") end
            needsDownload = true
        end
    else
        log("http.check failed or unavailable ("..tostring(handle_or_err or "N/A").."). Assuming download needed.")
        needsDownload = true
    end

    -- Always check if file exists locally, force download if missing
    if not fs.exists(config.localFilename) then
        log("Local file '" .. config.localFilename .. "' missing.")
        needsDownload = true
    end

    -- 2. Download if needed
    if needsDownload then
        log("Update required or first run/file missing.")
        local downloadHeaders = downloadAndSave() -- Attempt download
        if downloadHeaders and downloadHeaders["ETag"] then
            -- Update ETag based on the successful download's headers
            lastKnownETag = downloadHeaders["ETag"]
            log("Updated lastKnownETag to: " .. lastKnownETag)
        elseif currentETag then
             -- Fallback: If download failed but check gave us an ETag, use that.
             lastKnownETag = currentETag
             log("Download failed, using ETag from check: ".. lastKnownETag)
        else
             -- If check and download failed to get ETag, clear it.
             lastKnownETag = nil
             log("Could not get valid ETag from check or download.")
        end
    else
        log("No download required.")
    end

    -- 3. Execute the program (if it exists)
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

end -- End of while true loop
-- // =============================================================== //
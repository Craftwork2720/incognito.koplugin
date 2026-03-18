--[[--
Incognito Mode plugin for KOReader.

Opens a book without recording reading history, saving progress,
writing document settings to disk, or logging reading statistics.

@module koplugin.incognito
--]]--

local UIManager       = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _               = require("gettext")
local logger          = require("logger")

-- ── internal state ──────────────────────────────────────────────────────────
local M = {
    _active = false,
    _file   = nil,
}

-- ── ReadHistory patch ────────────────────────────────────────────────────────
local ok_rh, ReadHistory = pcall(require, "readhistory")
if ok_rh and ReadHistory then

    local orig_addItem = ReadHistory.addItem
    ReadHistory.addItem = function(self, file, ts, no_flush)
        if M._active and file == M._file then
            logger.dbg("Incognito: suppressing ReadHistory.addItem for", file)
            return
        end
        return orig_addItem(self, file, ts, no_flush)
    end

    local orig_reload = ReadHistory.reload
    ReadHistory.reload = function(self, force_read)
        orig_reload(self, force_read)
        if not M._active then return end
        local filtered = {}
        for _, item in ipairs(self.hist) do
            if item.file ~= M._file then
                table.insert(filtered, item)
            end
        end
        if #filtered ~= #self.hist then
            logger.dbg("Incognito: removing file from in-memory history")
            self.hist = filtered
        end
    end
end

-- ── DocumentRegistry patch ───────────────────────────────────────────────────
local ok_dr, DocumentRegistry = pcall(require, "document/documentregistry")
if ok_dr and DocumentRegistry then

    local orig_openDocument = DocumentRegistry.openDocument
    DocumentRegistry.openDocument = function(self, file, provider)
        local doc = orig_openDocument(self, file, provider)
        if doc and M._active and file == M._file then
            logger.dbg("Incognito: setting is_pic on document")
            doc.is_pic = true
        end
        return doc
    end
end

-- ── DocSettings class-level patch ────────────────────────────────────────────
local ok_ds, DocSettings = pcall(require, "docsettings")
if ok_ds and DocSettings then

    local orig_flush = DocSettings.flush
    DocSettings.flush = function(self_ds, ...)
        if M._active then
            logger.warn("Incognito: BLOCKED DocSettings:flush()")
            return
        end
        return orig_flush(self_ds, ...)
    end

else
    logger.warn("Incognito: WARNING – could not patch DocSettings.flush!")
end

-- ── ReaderUI patches ─────────────────────────────────────────────────────────
UIManager:scheduleIn(0, function()
    local ok_rui, ReaderUI = pcall(require, "apps/reader/readerui")
    if not ok_rui or not ReaderUI then
        logger.warn("Incognito: could not patch ReaderUI")
        return
    end

    -- saveSettings – belt-and-suspenders on top of DocSettings patch.
    local orig_saveSettings = ReaderUI.saveSettings
    ReaderUI.saveSettings = function(self_rui, ...)
        if M._active then
            logger.warn("Incognito: BLOCKED ReaderUI:saveSettings()")
            local Event = require("ui/event")
            self_rui:handleEvent(Event:new("SaveSettings"))
            return
        end
        return orig_saveSettings(self_rui, ...)
    end

    -- reloadDocument – block entirely during incognito.
    -- KOReader calls this after style/font changes that need a full DOM
    -- rebuild.  Allowing it would close the current session and reopen
    -- the file outside incognito, leaking history and settings.
    -- The rendering simply stays as-is; the user can reload after closing
    -- incognito if they want the style change to persist.
    local orig_reloadDocument = ReaderUI.reloadDocument
    if orig_reloadDocument then
        ReaderUI.reloadDocument = function(self_rui, ...)
            if M._active then
                logger.warn("Incognito: BLOCKED reloadDocument()")
                local Notification = require("ui/widget/notification")
                Notification:notify(_("Incognito: document reload suppressed"))
                return
            end
            return orig_reloadDocument(self_rui, ...)
        end
    end

    -- onClose – permanent class-level patch; runs for every ReaderUI close.
    local orig_onClose = ReaderUI.onClose
    ReaderUI.onClose = function(self_rui, ...)
        if not M._active then
            return orig_onClose(self_rui, ...)
        end

        local closed_file = M._file
        -- Run original while M._active is still true → flushes inside blocked.
        local ret = orig_onClose(self_rui, ...)

        M._active = false
        M._file   = nil
        logger.warn("Incognito: DEACTIVATED, closed file:", closed_file)

        if closed_file then
            local ok_bl, BookList = pcall(require, "ui/widget/booklist")
            if ok_bl and BookList and BookList.resetBookInfoCache then
                BookList.resetBookInfoCache(closed_file)
            end
        end

        return ret
    end
end)

-- ── FileManager "Open Incognito" button ──────────────────────────────────────
UIManager:scheduleIn(0, function()
    local ok_fm, FileManager = pcall(require, "apps/filemanager/filemanager")
    if not ok_fm or not FileManager then
        logger.warn("Incognito: FileManager not available, skipping button registration")
        return
    end

    FileManager:addFileDialogButtons("incognito", function(file, is_file)
        if not is_file then return nil end

        return {
            {
                text = _("Open Incognito"),
                callback = function()
                    M._active = true
                    M._file   = file
                    logger.warn("Incognito: ACTIVATED for", file)

                    local dialog = UIManager:getTopmostVisibleWidget()
                    if dialog then UIManager:close(dialog) end

                    UIManager:scheduleIn(0.1, function()
                        local ReaderUI = require("apps/reader/readerui")
                        ReaderUI:showReader(file)
                    end)
                end,
            },
        }
    end)
end)

-- ── WidgetContainer wrapper ───────────────────────────────────────────────────
local Incognito = WidgetContainer:extend{
    name        = "incognito",
    is_doc_only = false,
}

function Incognito:onDispatcherRegisterActions() end
function Incognito:init() self:onDispatcherRegisterActions() end

return Incognito

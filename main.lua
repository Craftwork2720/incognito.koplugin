--[[--
Incognito Mode plugin for KOReader.

Opens a book without recording reading history, saving progress,
writing document settings to disk, or logging reading statistics.

@module koplugin.incognito
--]]--

local Dispatcher      = require("dispatcher")
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
-- Setting is_pic = true on the document object prevents KOReader from writing
-- sidecar / statistics data for this session.
local ok_dr, DocumentRegistry = pcall(require, "document/documentregistry")
if ok_dr and DocumentRegistry then

    local orig_openDocument = DocumentRegistry.openDocument
    DocumentRegistry.openDocument = function(self, file, provider)
        local doc = orig_openDocument(self, file, provider)
        if doc and M._active and file == M._file then
            logger.dbg("Incognito: setting is_pic on document to suppress sidecar writes")
            doc.is_pic = true
        end
        return doc
    end
end

-- ── FileManager "Open Incognito" button ──────────────────────────────────────
-- Registered after a short delay so FileManager has time to initialise.
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
                    logger.dbg("Incognito: activated for", file)

                    -- Close the file dialog
                    local dialog = UIManager:getTopmostVisibleWidget()
                    if dialog then
                        UIManager:close(dialog)
                    end

                    UIManager:scheduleIn(0.1, function()
                        local ReaderUI = require("apps/reader/readerui")

                        -- Patch init: intercept doc_settings.flush so nothing
                        -- is written while incognito is active.
                        local orig_init = ReaderUI.init
                        ReaderUI.init = function(self_rui, ...)
                            ReaderUI.init = orig_init          -- restore immediately
                            orig_init(self_rui, ...)
                            if M._active and self_rui.doc_settings then
                                local ds = self_rui.doc_settings
                                local orig_flush = ds.flush
                                ds.flush = function(self_ds, ...)
                                    if M._active then
                                        logger.dbg("Incognito: suppressing doc_settings flush")
                                        return
                                    end
                                    return orig_flush(self_ds, ...)
                                end
                            end
                        end

                        -- Patch onClose: deactivate incognito after the reader
                        -- closes and clean up any cached book-info.
                        local orig_onClose = ReaderUI.onClose
                        ReaderUI.onClose = function(self_rui, ...)
                            ReaderUI.onClose = orig_onClose    -- restore immediately
                            local closed_file = M._file

                            local ret = orig_onClose(self_rui, ...)

                            M._active = false
                            M._file   = nil
                            logger.dbg("Incognito: deactivated, closed file:", closed_file)

                            -- Purge any book-info that may have been cached in
                            -- memory during the incognito session.
                            if closed_file then
                                local ok_bl, BookList = pcall(require, "ui/widget/booklist")
                                if ok_bl and BookList and BookList.resetBookInfoCache then
                                    BookList.resetBookInfoCache(closed_file)
                                end
                            end

                            return ret
                        end

                        ReaderUI:showReader(file)
                    end)
                end,
            },
        }
    end)
end)

-- ── WidgetContainer wrapper (required by plugin loader) ──────────────────────
local Incognito = WidgetContainer:extend{
    name        = "incognito",
    is_doc_only = false,
}

function Incognito:onDispatcherRegisterActions()
    -- No dispatcher actions needed for now; the entry point is the
    -- file-dialog button registered above.
end

function Incognito:init()
    self:onDispatcherRegisterActions()
    -- Intentionally not adding a main-menu entry; the plugin works entirely
    -- through the per-file dialog button.
end

return Incognito

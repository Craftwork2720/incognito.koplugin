--[[--
Incognito Mode plugin for KOReader.
@module koplugin.incognito
--]]--

local UIManager       = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _               = require("gettext")

local PLUGIN_ICONS_DIR = "plugins/incognito.koplugin/icons"
local ICON_NAME        = "cre.incognito"
local ORIG_ICON_NAME   = "cre.render.reload"

local M = {
    _active   = false,
    _file     = nil,
    _flipping = nil,
}

local ok_iw, IconWidget = pcall(require, "ui/widget/iconwidget")
if ok_iw and IconWidget then
    local icon_path = PLUGIN_ICONS_DIR .. "/" .. ICON_NAME .. ".svg"
    local orig_init = IconWidget.init
    IconWidget.init = function(self_iw, ...)
        if self_iw.icon == ICON_NAME and not self_iw.file and not self_iw.image then
            self_iw.file = icon_path
            return
        end
        return orig_init(self_iw, ...)
    end
end

local ok_rf, ReaderFlipping = pcall(require, "apps/reader/modules/readerflipping")
if ok_rf and ReaderFlipping then
    local orig_rf_init = ReaderFlipping.init
    ReaderFlipping.init = function(self_rf, ...)
        orig_rf_init(self_rf, ...)
        if M._active then
            self_rf.rolling_rendering_state_icons["RELOADING_DOCUMENT"] = ICON_NAME
            self_rf.rolling_rendering_state_widgets = nil
            M._flipping = self_rf
        end
    end
end

local ok_rh, ReadHistory = pcall(require, "readhistory")
if ok_rh and ReadHistory then
    local orig_addItem = ReadHistory.addItem
    ReadHistory.addItem = function(self, file, ts, no_flush)
        if M._active and file == M._file then return end
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
            self.hist = filtered
        end
    end
end

local ok_dr, DocumentRegistry = pcall(require, "document/documentregistry")
if ok_dr and DocumentRegistry then
    local orig_openDocument = DocumentRegistry.openDocument
    DocumentRegistry.openDocument = function(self, file, provider)
        local doc = orig_openDocument(self, file, provider)
        if doc and M._active and file == M._file then
            doc.is_pic = true
        end
        return doc
    end
end

local ok_ds, DocSettings = pcall(require, "docsettings")
if ok_ds and DocSettings then
    local orig_flush = DocSettings.flush
    DocSettings.flush = function(self_ds, ...)
        if M._active then return end
        return orig_flush(self_ds, ...)
    end
end

UIManager:scheduleIn(0, function()
    local ok_rui, ReaderUI = pcall(require, "apps/reader/readerui")
    if not ok_rui or not ReaderUI then return end

    local orig_saveSettings = ReaderUI.saveSettings
    ReaderUI.saveSettings = function(self_rui, ...)
        if M._active then
            self_rui:handleEvent(require("ui/event"):new("SaveSettings"))
            return
        end
        return orig_saveSettings(self_rui, ...)
    end

    local orig_reloadDocument = ReaderUI.reloadDocument
    if orig_reloadDocument then
        ReaderUI.reloadDocument = function(self_rui, ...)
            if M._active then
                require("ui/widget/notification"):notify(_("Incognito: document reload suppressed"))
                return
            end
            return orig_reloadDocument(self_rui, ...)
        end
    end

    local orig_onClose = ReaderUI.onClose
    ReaderUI.onClose = function(self_rui, ...)
        if not M._active then
            return orig_onClose(self_rui, ...)
        end
        local closed_file = M._file
        if M._flipping then
            M._flipping.rolling_rendering_state_icons["RELOADING_DOCUMENT"] = ORIG_ICON_NAME
            M._flipping.rolling_rendering_state_widgets = nil
            M._flipping = nil
        end
        local ret = orig_onClose(self_rui, ...)
        M._active = false
        M._file   = nil
        local ok_bl, BookList = pcall(require, "ui/widget/booklist")
        if ok_bl and BookList and BookList.resetBookInfoCache then
            BookList.resetBookInfoCache(closed_file)
        end
        return ret
    end
end)

UIManager:scheduleIn(0, function()
    local ok_fm, FileManager = pcall(require, "apps/filemanager/filemanager")
    if not ok_fm or not FileManager then return end

    local function row_func(file, is_file)
        if not is_file then return nil end
        return {
            {
                text = _("Open Incognito"),
                callback = function()
                    M._active = true
                    M._file   = file
                    local dialog = UIManager:getTopmostVisibleWidget()
                    if dialog then UIManager:close(dialog) end
                    UIManager:scheduleIn(0.1, function()
                        require("apps/reader/readerui"):showReader(file)
                    end)
                end,
            },
        }
    end

    FileManager.addFileDialogButtons(FileManager, "incognito", row_func)

    local ok_fmh, FileManagerHistory = pcall(require, "apps/filemanager/filemanagerhistory")
    if ok_fmh and FileManagerHistory then
        FileManager.addFileDialogButtons(FileManagerHistory, "incognito", row_func)
    end

    local ok_fmc, FileManagerCollection = pcall(require, "apps/filemanager/filemanagercollection")
    if ok_fmc and FileManagerCollection then
        FileManager.addFileDialogButtons(FileManagerCollection, "incognito", row_func)
    end

    local ok_fms, FileManagerFileSearcher = pcall(require, "apps/filemanager/filemanagerfilesearcher")
    if ok_fms and FileManagerFileSearcher then
        FileManager.addFileDialogButtons(FileManagerFileSearcher, "incognito", row_func)
    end
end)

local Incognito = WidgetContainer:extend{
    name        = "incognito",
    is_doc_only = false,
}

function Incognito:onDispatcherRegisterActions() end
function Incognito:init() self:onDispatcherRegisterActions() end

return Incognito
local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local Event = require("ui/event")
local InfoMessage = require("ui/widget/infomessage")
local Notification = require("ui/widget/notification")
local InputContainer = require("ui/widget/container/inputcontainer")
local TimeVal = require("ui/timeval")
local Translator = require("ui/translator")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template
local Screen = Device.screen

local ReaderHighlight = InputContainer:new{}

function ReaderHighlight:init()
    self.ui:registerPostInitCallback(function()
        self.ui.menu:registerToMainMenu(self)
    end)
end

function ReaderHighlight:setupTouchZones()
    -- deligate gesture listener to readerui
    self.ges_events = {}
    self.onGesture = nil

    if not Device:isTouchDevice() then return end

    self.ui:registerTouchZones({
        {
            id = "readerhighlight_tap",
            ges = "tap",
            screen_zone = {
                ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1,
            },
            overrides = {
                "tap_forward",
                "tap_backward",
                "readermenu_tap",
                "readerconfigmenu_tap",
            },
            handler = function(ges) return self:onTap(nil, ges) end
        },
        {
            id = "readerhighlight_hold",
            ges = "hold",
            screen_zone = {
                ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1,
            },
            handler = function(ges) return self:onHold(nil, ges) end
        },
        {
            id = "readerhighlight_hold_release",
            ges = "hold_release",
            screen_zone = {
                ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1,
            },
            handler = function() return self:onHoldRelease() end
        },
        {
            id = "readerhighlight_hold_pan",
            ges = "hold_pan",
            rate = 2.0,
            screen_zone = {
                ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1,
            },
            handler = function(ges) return self:onHoldPan(nil, ges) end
        },
    })
end

function ReaderHighlight:onReaderReady()
    self:setupTouchZones()
end

function ReaderHighlight:addToMainMenu(menu_items)
    -- insert table to main reader menu
    menu_items.highlight_options = {
        text = _("Highlighting"),
        sub_item_table = self:genHighlightDrawerMenu(),
    }
    menu_items.translation_settings = Translator:genSettingsMenu()
end

local highlight_style = {
    lighten = _("Lighten"),
    underscore = _("Underline"),
    invert = _("Invert"),
}

function ReaderHighlight:genHighlightDrawerMenu()
    local get_highlight_style = function(style)
        return {
            text = highlight_style[style],
            checked_func = function()
                return self.view.highlight.saved_drawer == style
            end,
            enabled_func = function()
                return not self.view.highlight.disabled
            end,
            callback = function()
                self.view.highlight.saved_drawer = style
            end
        }
    end
    return {
        {
            text = _("Allow highlighting"),
            checked_func = function()
                return not self.view.highlight.disabled
            end,
            callback = function()
                self.view.highlight.disabled = not self.view.highlight.disabled
            end,
            hold_callback = function(touchmenu_instance)
                self:makeDefault(not self.view.highlight.disabled)
            end,
            separator = true,
        },
        get_highlight_style("lighten"),
        get_highlight_style("underscore"),
        get_highlight_style("invert"),
    }
end

-- Returns a unique id, that can be provided on delayed call to :clear(id)
-- to ensure current highlight has not already been cleared, and that we
-- are not going to clear a new highlight
function ReaderHighlight:getClearId()
    self.clear_id = TimeVal.now() -- can act as a unique id
    return self.clear_id
end

function ReaderHighlight:clear(clear_id)
    if clear_id then -- should be provided by delayed call to clear()
        if clear_id ~= self.clear_id then
            -- if clear_id is no more valid, highlight has already been
            -- cleared since this clear_id was given
            return
        end
    end
    self.clear_id = nil -- invalidate id
    if self.ui.document.info.has_pages then
        self.view.highlight.temp = {}
    else
        self.ui.document:clearSelection()
    end
    if self.restore_page_mode_func then
        self.restore_page_mode_func()
        self.restore_page_mode_func = nil
    end
    self.selected_text_start_xpointer = nil
    if self.hold_pos then
        self.hold_pos = nil
        self.selected_text = nil
        UIManager:setDirty(self.dialog, "ui")
        return true
    end
end

function ReaderHighlight:onClearHighlight()
    self:clear()
    return true
end

function ReaderHighlight:onTap(_, ges)
    if not self:clear() then
        if self.ui.document.info.has_pages then
            return self:onTapPageSavedHighlight(ges)
        else
            return self:onTapXPointerSavedHighlight(ges)
        end
    end
end

local function inside_box(pos, box)
    if pos then
        local x, y = pos.x, pos.y
        if box.x <= x and box.y <= y
            and box.x + box.w >= x
            and box.y + box.h >= y then
            return true
        end
    end
end

function ReaderHighlight:onTapPageSavedHighlight(ges)
    local pages = self.view:getCurrentPageList()
    local pos = self.view:screenToPageTransform(ges.pos)
    for key, page in pairs(pages) do
        local items = self.view.highlight.saved[page]
        if items then
            for i = 1, #items do
                local pos0, pos1 = items[i].pos0, items[i].pos1
                local boxes = self.ui.document:getPageBoxesFromPositions(page, pos0, pos1)
                if boxes then
                    for index, box in pairs(boxes) do
                        if inside_box(pos, box) then
                            logger.dbg("Tap on highlight")
                            return self:onShowHighlightDialog(page, i)
                        end
                    end
                end
            end
        end
    end
end

function ReaderHighlight:onTapXPointerSavedHighlight(ges)
    -- Getting screen boxes is done for each tap on screen (changing pages,
    -- showing menu...). We might want to cache these boxes per page (and
    -- clear that cache when page layout change or highlights are added
    -- or removed).
    local cur_view_top, cur_view_bottom
    local pos = self.view:screenToPageTransform(ges.pos)
    for page, _ in pairs(self.view.highlight.saved) do
        local items = self.view.highlight.saved[page]
        if items then
            for i = 1, #items do
                local pos0, pos1 = items[i].pos0, items[i].pos1
                -- document:getScreenBoxesFromPositions() is expensive, so we
                -- first check this item is on current page
                if not cur_view_top then
                    -- Even in page mode, it's safer to use pos and ui.dimen.h
                    -- than pages' xpointers pos, even if ui.dimen.h is a bit
                    -- larger than pages' heights
                    cur_view_top = self.ui.document:getCurrentPos()
                    if self.view.view_mode == "page" and self.ui.document:getVisiblePageCount() > 1 then
                        cur_view_bottom = cur_view_top + 2 * self.ui.dimen.h
                    else
                        cur_view_bottom = cur_view_top + self.ui.dimen.h
                    end
                end
                local spos0 = self.ui.document:getPosFromXPointer(pos0)
                local spos1 = self.ui.document:getPosFromXPointer(pos1)
                local start_pos = math.min(spos0, spos1)
                local end_pos = math.max(spos0, spos1)
                if start_pos <= cur_view_bottom and end_pos >= cur_view_top then
                    local boxes = self.ui.document:getScreenBoxesFromPositions(pos0, pos1, true) -- get_segments=true
                    if boxes then
                        for index, box in pairs(boxes) do
                            if inside_box(pos, box) then
                                logger.dbg("Tap on highlight")
                                return self:onShowHighlightDialog(page, i)
                            end
                        end
                    end
                end
            end
        end
    end
end

function ReaderHighlight:updateHighlight(page, index, side, direction, move_by_char)
    if self.ui.document.info.has_pages then -- we do this only if it's epub file
        return
    end

    local highlight = self.view.highlight.saved[page][index]
    local highlight_time = highlight.datetime
    local highlight_beginning = highlight.pos0
    local highlight_end = highlight.pos1
    if side == 0 then -- we move pos0
        local updated_highlight_beginning
        if direction == 1 then -- move highlight to the right
            if move_by_char then
                updated_highlight_beginning = self.ui.document:getNextVisibleChar(highlight_beginning)
            else
                updated_highlight_beginning = self.ui.document:getNextVisibleWordStart(highlight_beginning)
            end
         else -- move highlight to the left
            if move_by_char then
                updated_highlight_beginning = self.ui.document:getPrevVisibleChar(highlight_beginning)
            else
                updated_highlight_beginning = self.ui.document:getPrevVisibleWordStart(highlight_beginning)
            end
        end
        if updated_highlight_beginning then
            local order = self.ui.document:compareXPointers(updated_highlight_beginning, highlight_end)
            if order and order > 0 then -- only if beginning did not go past end
                self.view.highlight.saved[page][index].pos0 = updated_highlight_beginning
            end
        end
    else -- we move pos1
        local updated_highlight_end
        if direction == 1 then -- move highlight to the right
            if move_by_char then
                updated_highlight_end = self.ui.document:getNextVisibleChar(highlight_end)
            else
                updated_highlight_end = self.ui.document:getNextVisibleWordEnd(highlight_end)
            end
        else -- move highlight to the left
            if move_by_char then
                updated_highlight_end = self.ui.document:getPrevVisibleChar(highlight_end)
            else
                updated_highlight_end = self.ui.document:getPrevVisibleWordEnd(highlight_end)
            end
        end
        if updated_highlight_end then
            local order = self.ui.document:compareXPointers(highlight_beginning, updated_highlight_end)
            if order and order > 0 then -- only if end did not go back past beginning
                self.view.highlight.saved[page][index].pos1 = updated_highlight_end
            end
        end
    end

    local new_beginning = self.view.highlight.saved[page][index].pos0
    local new_end = self.view.highlight.saved[page][index].pos1
    local new_text = self.ui.document:getTextFromXPointers(new_beginning, new_end)
    self.view.highlight.saved[page][index].text = new_text
    local new_highlight = self.view.highlight.saved[page][index]
    self.ui.bookmark:updateBookmark({
        page = highlight_beginning,
        datetime = highlight_time,
        updated_highlight = new_highlight
    }, true)
    UIManager:setDirty(self.dialog, "ui")
end

function ReaderHighlight:onShowHighlightDialog(page, index)
    local buttons = {
        {
            {
                text = _("Delete"),
                callback = function()
                    self:deleteHighlight(page, index)
                    -- other part outside of the dialog may be dirty
                    UIManager:close(self.edit_highlight_dialog, "ui")
                end,
            },
            {
                text = _("Edit"),
                callback = function()
                    self:editHighlight(page, index)
                    UIManager:close(self.edit_highlight_dialog)
                end,
            },
        }
    }

    if not self.ui.document.info.has_pages then
        table.insert(buttons, {
            {
                text = "◁⇱",
                callback = function()
                    self:updateHighlight(page, index, 0, -1, false)
                end,
                hold_callback = function()
                    self:updateHighlight(page, index, 0, -1, true)
                    return true
                end
            },
            {
                text = "⇱▷",
                callback = function()
                    self:updateHighlight(page, index, 0, 1, false)
                end,
                hold_callback = function()
                    self:updateHighlight(page, index, 0, 1, true)
                    return true
                end
            },
            {
                text = "◁⇲",
                callback = function()
                    self:updateHighlight(page, index, 1, -1, false)
                end,
                hold_callback = function()
                    self:updateHighlight(page, index, 1, -1, true)
                end
            },
            {
                text = "⇲▷",
                callback = function()
                    self:updateHighlight(page, index, 1, 1, false)
                end,
                hold_callback = function()
                    self:updateHighlight(page, index, 1, 1, true)
                end
            }
        })
    end
    self.edit_highlight_dialog = ButtonDialog:new{
        buttons = buttons
    }
    UIManager:show(self.edit_highlight_dialog)
    return true
end

function ReaderHighlight:onHold(arg, ges)
    -- disable hold gesture if highlighting is disabled
    if self.view.highlight.disabled then return true end
    self:clear() -- clear previous highlight (delayed clear may not have done it yet)
    self.hold_ges_pos = ges.pos -- remember hold original gesture position
    self.hold_pos = self.view:screenToPageTransform(ges.pos)
    logger.dbg("hold position in page", self.hold_pos)
    if not self.hold_pos then
        logger.dbg("not inside page area")
        return true
    end

    -- check if we were holding on an image
    -- we provide want_frames=true, so we get a list of images for
    -- animated GIFs (supported by ImageViewer)
    local image = self.ui.document:getImageFromPosition(self.hold_pos, true)
    if image then
        logger.dbg("hold on image")
        local ImageViewer = require("ui/widget/imageviewer")
        local imgviewer = ImageViewer:new{
            image = image,
            -- title_text = _("Document embedded image"),
            -- No title, more room for image
            with_title_bar = false,
            fullscreen = true,
        }
        UIManager:show(imgviewer)
        return true
    end

    -- otherwise, we must be holding on text
    local ok, word = pcall(self.ui.document.getWordFromPosition, self.ui.document, self.hold_pos)
    if ok and word then
        logger.dbg("selected word:", word)
        self.selected_word = word
        local link = self.ui.link:getLinkFromGes(ges)
        self.selected_link = nil
        if link then
            logger.dbg("link:", link)
            self.selected_link = link
        end
        if self.ui.document.info.has_pages then
            local boxes = {}
            table.insert(boxes, self.selected_word.sbox)
            self.view.highlight.temp[self.hold_pos.page] = boxes
        end
        UIManager:setDirty(self.dialog, "ui")
        -- TODO: only mark word?
        -- Unfortunately, CREngine does not return good coordinates
        -- UIManager:setDirty(self.dialog, "partial", self.selected_word.sbox)
        self.hold_start_tv = TimeVal.now()
        if word.pos0 then
            -- Remember original highlight start position, so we can show
            -- a marker when back from across-pages text selection, which
            -- is handled in onHoldPan()
            self.selected_text_start_xpointer = word.pos0
        end
    end
    return true
end

function ReaderHighlight:onHoldPan(_, ges)
    if self.hold_pos == nil then
        logger.dbg("no previous hold position")
        return true
    end
    local page_area = self.view:getScreenPageArea(self.hold_pos.page)
    if ges.pos:notIntersectWith(page_area) then
        logger.dbg("not inside page area", ges, page_area)
        return true
    end

    self.holdpan_pos = self.view:screenToPageTransform(ges.pos)
    logger.dbg("holdpan position in page", self.holdpan_pos)

    if not self.ui.document.info.has_pages and self.selected_text_start_xpointer then
        -- With CreDocuments, allow text selection across multiple pages
        -- by (temporarily) switching to scroll mode when panning to the
        -- top left or bottom right corners.
        local is_in_top_left_corner = self.holdpan_pos.y < 1/8*Screen:getHeight()
                                  and self.holdpan_pos.x < 1/8*Screen:getWidth()
        local is_in_bottom_right_corner = self.holdpan_pos.y > 7/8*Screen:getHeight()
                                      and self.holdpan_pos.x > 7/8*Screen:getWidth()
        if is_in_top_left_corner or is_in_bottom_right_corner then
            if self.was_in_some_corner then
                -- Do nothing, wait for the user to move his finger out of that corner
                return true
            end
            self.was_in_some_corner = true
            if self.ui.document:getVisiblePageCount() == 1 then -- single page mode
                -- We'll adjust hold_pos.y after the mode switch and the scroll
                -- so it's accurate in the new screen coordinates
                local orig_y = self.ui.document:getScreenPositionFromXPointer(self.selected_text_start_xpointer)
                if self.view.view_mode ~= "scroll" then
                    -- Switch from page mode to scroll mode
                    local restore_page_mode_xpointer = self.ui.document:getXPointer() -- top of current page
                    self.restore_page_mode_func = function()
                        self.ui:handleEvent(Event:new("SetViewMode", "page"))
                        self.ui.rolling:onGotoXPointer(restore_page_mode_xpointer, self.selected_text_start_xpointer)
                    end
                    self.ui:handleEvent(Event:new("SetViewMode", "scroll"))
                end
                -- (using rolling:onGotoViewRel(1/3) has some strange side effects)
                local scroll_distance = math.floor(Screen:getHeight() * 1/3)
                local move_y = is_in_bottom_right_corner and scroll_distance or -scroll_distance
                self.ui.rolling:_gotoPos(self.ui.document:getCurrentPos() + move_y)
                local new_y = self.ui.document:getScreenPositionFromXPointer(self.selected_text_start_xpointer)
                self.hold_pos.y = self.hold_pos.y - orig_y + new_y
                UIManager:setDirty(self.dialog, "ui")
                return true
            else -- two pages mode
                -- We don't switch to scroll mode: we just turn 1 page to
                -- allow continuing the selection.
                -- Unlike in 1-page mode, we have a limitation here: we can't adjust
                -- the selection to further than current page and prev/next one.
                -- So don't handle another corner if we already handled one:
                if self.restore_page_mode_func then
                    return true
                end
                -- Also, we are not able to move hold_pos.x out of screen,
                -- so if we started on the right page, ignore top left corner,
                -- and if we started on the left page, ignore bottom right corner.
                local screen_half_width = math.floor(Screen:getWidth() * 1/2)
                if self.hold_pos.x >= screen_half_width and is_in_top_left_corner then
                    return true
                elseif self.hold_pos.x <= screen_half_width and is_in_bottom_right_corner then
                    return true
                end
                local cur_page = self.ui.document:getCurrentPage()
                local restore_page_mode_xpointer = self.ui.document:getXPointer() -- top of current page
                self.restore_page_mode_func = function()
                    self.ui.rolling:onGotoXPointer(restore_page_mode_xpointer, self.selected_text_start_xpointer)
                end
                if is_in_bottom_right_corner then
                    self.ui.rolling:_gotoPage(cur_page + 1, true) -- no odd left page enforcement
                    self.hold_pos.x = self.hold_pos.x - screen_half_width
                else
                    self.ui.rolling:_gotoPage(cur_page - 1, true) -- no odd left page enforcement
                    self.hold_pos.x = self.hold_pos.x + screen_half_width
                end
                UIManager:setDirty(self.dialog, "ui")
                return true
            end
        else
            self.was_in_some_corner = nil
        end
    end

    local old_text = self.selected_text and self.selected_text.text
    self.selected_text = self.ui.document:getTextFromPositions(self.hold_pos, self.holdpan_pos)

    if self.selected_text and self.selected_text.pos0 then
        if not self.selected_text_start_xpointer then
            -- This should have been set in onHold(), where we would get
            -- a precise pos0 on the first word selected.
            -- Do it here too in case onHold() missed it, but it could be
            -- less precise (getTextFromPositions() does order pos0 and pos1,
            -- so it's not certain pos0 is where we started from; we get
            -- the ones from the first pan, and if it is not small enough
            -- and spans quite some height, the marker could point away
            -- from the start position)
            self.selected_text_start_xpointer = self.selected_text.pos0
        end
    end

    if self.selected_text and old_text and old_text == self.selected_text.text then
        -- no modification
        return
    end
    logger.dbg("selected text:", self.selected_text)
    if self.selected_text then
        self.view.highlight.temp[self.hold_pos.page] = self.selected_text.sboxes
        -- remove selected word if hold moves out of word box
        if not self.selected_text.sboxes or #self.selected_text.sboxes == 0 then
            self.selected_word = nil
        elseif self.selected_word and not self.selected_word.sbox:contains(self.selected_text.sboxes[1]) or
            #self.selected_text.sboxes > 1 then
            self.selected_word = nil
        end
    end
    UIManager:setDirty(self.dialog, "ui")
end

local info_message_ocr_text = _([[
No OCR results or no language data.

KOReader has a build-in OCR engine for recognizing words in scanned PDF and DjVu documents. In order to use OCR in scanned pages, you need to install tesseract trained data for your document language.

You can download language data files for version 3.04 from https://github.com/tesseract-ocr/tesseract/wiki/Data-Files

Copy the language data files for Tesseract 3.04 (e.g., eng.traineddata for English and spa.traineddata for Spanish) into koreader/data/tessdata]])

function ReaderHighlight:lookup(selected_word, selected_link)
    -- if we extracted text directly
    if selected_word.word then
        local word_box = self.view:pageToScreenTransform(self.hold_pos.page, selected_word.sbox)
        self.ui:handleEvent(Event:new("LookupWord", selected_word.word, word_box, self, selected_link))
    -- or we will do OCR
    elseif selected_word.sbox and self.hold_pos then
        local word = self.ui.document:getOCRWord(self.hold_pos.page, selected_word)
        logger.dbg("OCRed word:", word)
        if word and word ~= "" then
            local word_box = self.view:pageToScreenTransform(self.hold_pos.page, selected_word.sbox)
            self.ui:handleEvent(Event:new("LookupWord", word, word_box, self, selected_link))
        else
            UIManager:show(InfoMessage:new{
                text = info_message_ocr_text,
            })
        end
    end
end

local function prettifyCss(css_text)
    -- This is not perfect, but enough to make some ugly CSS readable.
    -- Get rid of \t so we can use it as a replacement/hiding char
    css_text = css_text:gsub("\t", " ")
    -- Wrap and indent declarations
    css_text = css_text:gsub("%s*{%s*", " {\n    ")
    css_text = css_text:gsub(";%s*}%s*", ";\n}\n")
    css_text = css_text:gsub(";%s*([^}])", ";\n    %1")
    css_text = css_text:gsub("%s*}%s*", "\n}\n")
    -- Cleanup declarations
    css_text = css_text:gsub("{[^}]*}", function(s)
        s = s:gsub("%s*:%s*", ": ")
        -- Temporarily hide/replace ',' in declaration so they
        -- are not matched and made multi-lines by followup gsub
        s = s:gsub("%s*,%s*", "\t")
        return s
    end)
    -- Have each selector (separated by ',') on a new line
    css_text = css_text:gsub("%s*,%s*", " ,\n")
    -- Restore hidden ',' in declarations
    css_text = css_text:gsub("\t", ", ")
    return css_text
end

function ReaderHighlight:viewSelectionHTML(debug_view)
    if self.ui.document.info.has_pages then
        return
    end
    if self.selected_text and self.selected_text.pos0 and self.selected_text.pos1 then
        -- For available flags, see the "#define WRITENODEEX_*" in crengine/src/lvtinydom.cpp
        local html_flags = 0x3030 -- valid and classic displayed HTML, with only block nodes indented
        if not debug_view then
            debug_view = 0
        end
        if debug_view == 1 then
            -- Each node on a line, with markers and numbers of skipped chars and siblings shown,
            -- with possibly invalid HTML (text nodes not escaped)
            html_flags = 0x3353
        elseif debug_view == 2 then
            -- Additionally see rendering methods and unicode codepoint of each char
            html_flags = 0x3757
        end
        local html, css_files = self.ui.document:getHTMLFromXPointers(self.selected_text.pos0,
                                    self.selected_text.pos1, html_flags, true)
        if html then
            -- Make some invisible chars visible
            if debug_view >= 1 then
                html = html:gsub("\xC2\xA0", "␣")  -- no break space: open box
                html = html:gsub("\xC2\xAD", "⋅") -- soft hyphen: dot operator (smaller than middle dot ·)
                -- Prettify inlined CSS (from <HEAD>, put in an internal
                -- <body><stylesheet> element by crengine (the opening tag may
                -- include some href=, or end with " ~X>" with some html_flags)
                -- (We do that in debug_view mode only: as this may increase
                -- the height of this section, we don't want to have to scroll
                -- many pages to get to the HTML content on the initial view.)
                html = html:gsub("(<stylesheet[^>]*>)%s*(.-)%s*(</stylesheet>)", function(pre, css_text, post)
                    return pre .. "\n" .. prettifyCss(css_text) .. post
                end)
            end
            local TextViewer = require("ui/widget/textviewer")
            local Font = require("ui/font")
            local textviewer
            local buttons_table = {}
            if css_files then
                for i=1, #css_files do
                    local button = {
                        text = T(_("View %1"), css_files[i]),
                        callback = function()
                            local css_text = self.ui.document:getDocumentFileContent(css_files[i])
                            local cssviewer
                            cssviewer = TextViewer:new{
                                title = css_files[i],
                                text = css_text or _("Failed getting CSS content"),
                                text_face = Font:getFace("smallinfont"),
                                justified = false,
                                buttons_table = {
                                    {{
                                        text = _("Prettify"),
                                        enabled = css_text and true or false,
                                        callback = function()
                                            UIManager:close(cssviewer)
                                            UIManager:show(TextViewer:new{
                                                title = css_files[i],
                                                text = prettifyCss(css_text),
                                                text_face = Font:getFace("smallinfont"),
                                                justified = false,
                                            })
                                        end,
                                    }},
                                    {{
                                        text = _("Close"),
                                        callback = function()
                                            UIManager:close(cssviewer)
                                        end,
                                    }},
                                }
                            }
                            UIManager:show(cssviewer)
                        end,
                    }
                    -- One button per row, too make room for the possibly long css filename
                    table.insert(buttons_table, {button})
                end
            end
            local next_debug_text
            local next_debug_view = debug_view + 1
            if next_debug_view == 1 then
                next_debug_text = _("Switch to debug view")
            elseif next_debug_view == 2 then
                next_debug_text = _("Switch to extended debug view")
            else
                next_debug_view = 0
                next_debug_text = _("Switch to standard view")
            end
            table.insert(buttons_table, {{
                text = next_debug_text,
                callback = function()
                    UIManager:close(textviewer)
                    self:viewSelectionHTML(next_debug_view)
                end,
            }})
            table.insert(buttons_table, {{
                text = _("Close"),
                callback = function()
                    UIManager:close(textviewer)
                end,
            }})
            textviewer = TextViewer:new{
                title = _("Selection HTML"),
                text = html,
                text_face = Font:getFace("smallinfont"),
                justified = false,
                buttons_table = buttons_table,
            }
            UIManager:show(textviewer)
        else
            UIManager:show(InfoMessage:new{
                text = _("Failed getting HTML for selection"),
            })
        end
    end
end

function ReaderHighlight:translate(selected_text)
    if selected_text.text ~= "" then
        self:onTranslateText(selected_text.text)
    -- or we will do OCR
    else
        local text = self.ui.document:getOCRText(self.hold_pos.page, selected_text)
        logger.dbg("OCRed text:", text)
        if text and text ~= "" then
            self:onTranslateText(text)
        else
            UIManager:show(InfoMessage:new{
                text = info_message_ocr_text,
            })
        end
    end
end

function ReaderHighlight:onTranslateText(text)
    Translator:showTranslation(text)
end

function ReaderHighlight:onHoldRelease()
    if self.hold_start_tv then
        local hold_duration = TimeVal.now() - self.hold_start_tv
        hold_duration = hold_duration.sec + hold_duration.usec/1000000
        self.hold_start_tv = nil
        if hold_duration > 3.0 and self.selected_word then
            -- if we were holding for more than 3 seconds on a word, make
            -- it behave like we panned and selected more words, so we can
            -- directly access the highlight menu and avoid a dict lookup
            self:onHoldPan(nil, {pos=self.hold_ges_pos})
        end
    end

    if self.selected_text then
        local default_highlight_action = G_reader_settings:readSetting("default_highlight_action")
        if not default_highlight_action then
            local highlight_buttons = {
                {
                    {
                        text = _("Highlight"),
                        callback = function()
                            self:saveHighlight()
                            self:onClose()
                        end,
                    },
                    {
                        text = _("Add Note"),
                        callback = function()
                            self:addNote()
                            self:onClose()
                        end,
                    },
                },
                {
                    {
                        text = "Copy",
                        enabled = Device:hasClipboard(),
                        callback = function()
                            Device.input.setClipboardText(self.selected_text.text)
                        end,
                    },
                    {
                        text = _("View HTML"),
                        enabled = not self.ui.document.info.has_pages,
                        callback = function()
                            self:viewSelectionHTML()
                        end,
                    },
                },
                {
                    {
                        text = _("Wikipedia"),
                        callback = function()
                            UIManager:scheduleIn(0.1, function()
                                self:lookupWikipedia()
                                -- We don't call self:onClose(), we need the highlight
                                -- to still be there, as we may Highlight it from the
                                -- dict lookup widget
                            end)
                        end,
                    },
                    {
                        text = _("Dictionary"),
                        callback = function()
                            self:onHighlightDictLookup()
                            -- We don't call self:onClose(), same reason as above
                        end,
                    },
                },
                {
                    {
                        text = _("Translate"),
                        callback = function()
                            self:translate(self.selected_text)
                            -- We don't call self:onClose(), so one can still see
                            -- the highlighted text when moving the translated
                            -- text window, and also if NetworkMgr:promptWifiOn()
                            -- is needed, so the user can just tap again on this
                            -- button and does not need to select the text again.
                        end,
                    },
                    {
                        text = _("Search"),
                        callback = function()
                            self:onHighlightSearch()
                            UIManager:close(self.highlight_dialog)
                        end,
                    },
                },
            }
            if self.selected_link ~= nil then
                table.insert(highlight_buttons, { -- for now, a single button in an added row
                    {
                        text = _("Follow Link"),
                        callback = function()
                            self.ui.link:onGotoLink(self.selected_link)
                            self:onClose()
                        end,
                    },
                })
            end
            self.highlight_dialog = ButtonDialog:new{
                buttons = highlight_buttons,
                tap_close_callback = function() self:handleEvent(Event:new("Tap")) end,
            }
            UIManager:show(self.highlight_dialog)
        elseif default_highlight_action == "highlight" then
            self:saveHighlight()
            self:onClose()
        elseif default_highlight_action == "translate" then
            self:translate(self.selected_text)
            self:onClose()
        elseif default_highlight_action == "wikipedia" then
            self:lookupWikipedia()
            self:onClose()
        end
    elseif self.selected_word then
        self:lookup(self.selected_word, self.selected_link)
        self.selected_word = nil
    end
    return true
end

function ReaderHighlight:onCycleHighlightAction()
    local next_actions = {
        highlight = "translate",
        translate = "wikipedia",
        wikipedia = nil
    }
    local current_action = G_reader_settings:readSetting("default_highlight_action")
    if not current_action then
        G_reader_settings:saveSetting("default_highlight_action", "highlight")
        UIManager:show(Notification:new{
            text = _("Default highlight action changed to 'highlight'."),
            timeout = 1,
        })
    else
        local next_action = next_actions[current_action]
        G_reader_settings:saveSetting("default_highlight_action", next_action)
        UIManager:show(Notification:new{
            text = T(_("Default highlight action changed to '%1'."), (next_action or "default")),
            timeout = 1,
        })
    end
    return true
end

function ReaderHighlight:onCycleHighlightStyle()
    local next_actions = {
        lighten = "underscore",
        underscore = "invert",
        invert = "lighten"
    }
    self.view.highlight.saved_drawer = next_actions[self.view.highlight.saved_drawer]
    self.ui.doc_settings:saveSetting("highlight_drawer", self.view.highlight.saved_drawer)
    UIManager:show(Notification:new{
        text = T(_("Default highlight style changed to '%1'."), self.view.highlight.saved_drawer),
        timeout = 1,
    })
    return true
end

function ReaderHighlight:highlightFromHoldPos()
    if self.hold_pos then
        if not self.selected_text then
            self.selected_text = self.ui.document:getTextFromPositions(self.hold_pos, self.hold_pos)
            logger.dbg("selected text:", self.selected_text)
        end
    end
end

function ReaderHighlight:onHighlight()
    self:saveHighlight()
end

function ReaderHighlight:onUnhighlight(bookmark_item)
    local page
    local sel_text
    local sel_pos0
    local datetime
    local idx
    if bookmark_item then -- called from Bookmarks menu onHold
        page = bookmark_item.page
        sel_text = bookmark_item.notes
        sel_pos0 = bookmark_item.pos0
        datetime = bookmark_item.datetime
    else -- called from DictQuickLookup Unhighlight button
        page = self.hold_pos.page
        sel_text = self.selected_text.text
        sel_pos0 = self.selected_text.pos0
    end
    if self.ui.document.info.has_pages then -- We can safely use page
        for index = 1, #self.view.highlight.saved[page] do
            local highlight = self.view.highlight.saved[page][index]
            -- pos0 are tables and can't be compared directly, except when from
            -- DictQuickLookup where these are the same object.
            -- If bookmark_item provided, just check datetime
            if highlight.text == sel_text and (
                    (datetime == nil and highlight.pos0 == sel_pos0) or
                    (datetime ~= nil and highlight.datetime == datetime)) then
                idx = index
                break
            end
        end
    else -- page is a xpointer
        -- The original page could be found in bookmark_item.text, but
        -- no more if it has been renamed: we need to loop through all
        -- highlights on all page slots
        for p, highlights in pairs(self.view.highlight.saved) do
            for index = 1, #highlights do
                local highlight = highlights[index]
                -- pos0 are strings and can be compared directly
                if highlight.text == sel_text and (
                        (datetime == nil and highlight.pos0 == sel_pos0) or
                        (datetime ~= nil and highlight.datetime == datetime)) then
                    page = p -- this is the original page slot
                    idx = index
                    break
                end
            end
            if idx then
                break
            end
        end
    end
    if bookmark_item and not idx then
        logger.warn("unhighlight: bookmark_item not found among highlights", bookmark_item)
        -- Remove it from bookmarks anyway, so we're not stuck with an
        -- unremovable bookmark
        self.ui.bookmark:removeBookmark(bookmark_item)
        return
    end
    logger.dbg("found highlight to delete on page", page, idx)
    self:deleteHighlight(page, idx, bookmark_item)
    return true
end

function ReaderHighlight:getHighlightBookmarkItem()
    if self.hold_pos and not self.selected_text then
        self:highlightFromHoldPos()
    end
    if self.selected_text and self.selected_text.pos0 and self.selected_text.pos1 then
        local datetime = os.date("%Y-%m-%d %H:%M:%S")
        local page = self.ui.document.info.has_pages and
                self.hold_pos.page or self.selected_text.pos0
        return {
            page = page,
            pos0 = self.selected_text.pos0,
            pos1 = self.selected_text.pos1,
            datetime = datetime,
            notes = self.selected_text.text,
            highlighted = true,
        }
    end
end

function ReaderHighlight:saveHighlight()
    self.ui:handleEvent(Event:new("AddHighlight"))
    logger.dbg("save highlight")
    local page = self.hold_pos.page
    if self.hold_pos and self.selected_text and self.selected_text.pos0
        and self.selected_text.pos1 then
        if not self.view.highlight.saved[page] then
            self.view.highlight.saved[page] = {}
        end
        local datetime = os.date("%Y-%m-%d %H:%M:%S")
        local hl_item = {
            datetime = datetime,
            text = self.selected_text.text,
            pos0 = self.selected_text.pos0,
            pos1 = self.selected_text.pos1,
            pboxes = self.selected_text.pboxes,
            drawer = self.view.highlight.saved_drawer,
        }
        table.insert(self.view.highlight.saved[page], hl_item)
        local bookmark_item = self:getHighlightBookmarkItem()
        if bookmark_item then
            self.ui.bookmark:addBookmark(bookmark_item)
        end
        --[[
        -- disable exporting highlights to My Clippings
        -- since it's not portable and there is a better Evernote plugin
        -- to do the same thing
        if self.selected_text.text ~= "" then
            self:exportToClippings(page, hl_item)
        end
        --]]
        if self.selected_text.pboxes then
            self:exportToDocument(page, hl_item)
        end
        return page, #self.view.highlight.saved[page]
    end
end

--[[
function ReaderHighlight:exportToClippings(page, item)
    logger.dbg("export highlight to clippings", item)
    local clippings = io.open("/mnt/us/documents/My Clippings.txt", "a+")
    if clippings and item.text then
        local current_locale = os.setlocale()
        os.setlocale("C")
        clippings:write(self.document.file:gsub("(.*/)(.*)", "%2").."\n")
        clippings:write("- KOReader Highlight Page "..page.." ")
        clippings:write("| Added on "..os.date("%A, %b %d, %Y %I:%M:%S %p\n\n"))
        -- My Clippings only holds one line of highlight
        clippings:write(item["text"]:gsub("\n", " ").."\n")
        clippings:write("==========\n")
        clippings:close()
        os.setlocale(current_locale)
    end
end
--]]

function ReaderHighlight:exportToDocument(page, item)
    logger.dbg("export highlight to document", item)
    self.ui.document:saveHighlight(page, item)
end

function ReaderHighlight:addNote()
    local page, index = self:saveHighlight()
    self:editHighlight(page, index)
    UIManager:close(self.edit_highlight_dialog)
    self.ui:handleEvent(Event:new("AddNote"))
end

function ReaderHighlight:lookupWikipedia()
    if self.selected_text then
        self.ui:handleEvent(Event:new("LookupWikipedia", self.selected_text.text))
    end
end

function ReaderHighlight:onHighlightSearch()
    logger.dbg("search highlight")
    self:highlightFromHoldPos()
    if self.selected_text then
        local text = require("util").stripePunctuations(self.selected_text.text)
        self.ui:handleEvent(Event:new("ShowSearchDialog", text))
    end
end

function ReaderHighlight:onHighlightDictLookup()
    logger.dbg("dictionary lookup highlight")
    self:highlightFromHoldPos()
    if self.selected_text then
        self.ui:handleEvent(Event:new("LookupWord", self.selected_text.text))
    end
end

function ReaderHighlight:shareHighlight()
    logger.info("share highlight")
end

function ReaderHighlight:moreAction()
    logger.info("more action")
end

function ReaderHighlight:deleteHighlight(page, i, bookmark_item)
    self.ui:handleEvent(Event:new("DelHighlight"))
    logger.dbg("delete highlight", page, i)
    local removed = table.remove(self.view.highlight.saved[page], i)
    if bookmark_item then
        self.ui.bookmark:removeBookmark(bookmark_item)
    else
        self.ui.bookmark:removeBookmark({
            page = self.ui.document.info.has_pages and page or removed.pos0,
            datetime = removed.datetime,
        })
    end
end

function ReaderHighlight:editHighlight(page, i)
    local item = self.view.highlight.saved[page][i]
    self.ui.bookmark:renameBookmark({
        page = self.ui.document.info.has_pages and page or item.pos0,
        datetime = item.datetime,
    }, true)
end

function ReaderHighlight:onReadSettings(config)
    self.view.highlight.saved_drawer = config:readSetting("highlight_drawer") or self.view.highlight.saved_drawer
    local disable_highlight = config:readSetting("highlight_disabled")
    if disable_highlight == nil then
        disable_highlight = G_reader_settings:readSetting("highlight_disabled") or false
    end
    self.view.highlight.disabled = disable_highlight
end

function ReaderHighlight:onSaveSettings()
    self.ui.doc_settings:saveSetting("highlight_drawer", self.view.highlight.saved_drawer)
    self.ui.doc_settings:saveSetting("highlight_disabled", self.view.highlight.disabled)
end

function ReaderHighlight:onClose()
    UIManager:close(self.highlight_dialog)
    -- clear highlighted text
    self:clear()
end

function ReaderHighlight:makeDefault(highlight_disabled)
    local new_text
    if highlight_disabled then
        new_text = _("Disable highlight by default.")
    else
        new_text = _("Enable highlight by default.")
    end
    UIManager:show(ConfirmBox:new{
        text = new_text,
        ok_callback = function()
            G_reader_settings:saveSetting("highlight_disabled", highlight_disabled)
        end,
    })
end

return ReaderHighlight

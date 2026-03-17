
MTR_Tooltip = {}

function MTR_Tooltip:Show(frame, itemLink, bag, slot)
    GameTooltip:SetOwner(frame, "ANCHOR_RIGHT")

    if itemLink then
        GameTooltip:SetHyperlink(itemLink)
    elseif bag and slot then
        GameTooltip:SetBagItem(bag, slot)
    elseif frame and frame:GetID() then
        GameTooltip:SetInventoryItem("player", frame:GetID())
    end

    GameTooltip:Show()
end

function MTR_Tooltip:Hide()
    GameTooltip:Hide()
end

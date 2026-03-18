local function show_hint()
    local text = "Welcome to CastoricePS\n"
    text = text .. "This server is free.\n"
    text = text .. "Discord: https://discord.gg/CastoricePS\n"
    CS.RPG.Client.ConfirmDialogUtil.ShowCustomOkCancelHint(text, nil)
end

show_hint()

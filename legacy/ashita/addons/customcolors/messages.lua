local item     = "[A-Za-z0-9%_%'%.%: ]+"
local messages =
{
    -- === Your custom messages here ===
    -- { Pattern, { Colors } },

    -- === Party Finder (server broadcast) ===
    { "(.+) is looking for members: ([A-Za-z]+) %(Lv%d+%) _ (.+)", { 69, 105, 86 } },
    { "(.+) is looking for members: ([A-Za-z]+) %(Lv%d+%)",        { 69, 105 } },

    -- === Party Finder (addon messages) ===
    { "%[PartyFinder%] Join request sent to (.+) %(",                 { 69 } },
    { "%[PartyFinder%] (.+) accepted your join request!",             { 2 } },
    { "%[PartyFinder%] (.+) denied your request: (.+)",               { 68, 86 } },
    { "%[PartyFinder%] (.+) wants to join your party%.",              { 69 } },
    { "%[PartyFinder%] (.+) joined via Party Finder",                 { 2 } },
    { "%[PartyFinder%] Accepted (.+)",                                { 2 } },
    { "%[PartyFinder%] Denied (.+): level",                           { 68 } },
    { "%[PartyFinder%] Denied (.+)",                                  { 68 } },
    { "%[PartyFinder%] Auto_accepted party invite from (.+)",         { 2 } },
    { "%[PartyFinder%] You are now registered%.",                      2 },
    { "%[PartyFinder%] Registration withdrawn%.",                      68 },
    { "%[PartyFinder%] You are not registered%.",                      68 },
    { "%[PartyFinder%] Your LFM listing was removed",                  68 },
    { "%[PartyFinder%] No DFP awarded %- (.+)",                        68 },
    { "%[PartyFinder%] (.+) started (.+): (.+)",                      { 69, 105, 86 } },
    { "%[PartyFinder%] (.+) commenced! Teleporting",                  { 2 } },
    { "%[PartyFinder%] (.+) is ready!",                               { 2 } },
    { "%[PartyFinder%] (.+) declined%. (.+) cancelled%.",             { 68, 86 } },
    { "%[PartyFinder%] (.+) ready check timed out%.",                 { 68 } },
    { "%[PartyFinder%] You declined the (.+)%.",                      { 68 } },
    { "%[PartyFinder%] (%d+ players*) looking for group, (%d+ groups*) recruiting", { 69, 105 } },
    { "%[PartyFinder%] LFM notifications (ON)",                       { 2 } },
    { "%[PartyFinder%] LFM notifications (OFF)",                      { 68 } },
    { "%[PartyFinder%] Blocked (.+) from",                            { 68 } },
    { "%[PartyFinder%] Unblocked (.+)",                               { 2 } },
    { "%[PartyFinder%] Cannot join",                                   68 },
    { "%[PartyFinder%] Currently unavailable",                         68 },
    { "%[PartyFinder%] Background image not found",                    68 },
    { "%[PartyFinder%] Keybind set to (.+)",                          { 69 } },
    { "%[PartyFinder%] Keybind cleared%.",                             69 },
    { "%[PartyFinder%] Tutorial reset%.",                              69 },
    { "%[PartyFinder%] Blocked: (.+)",                                { 86 } },
    { "%[PartyFinder%] Blocklist is empty%.",                          86 },
    { "%[PartyFinder%] Dev mode: (.+)",                               { 69 } },
    { "%[PartyFinder%] Tooltips (.+)",                                { 69 } },
    { "%[PartyFinder%] (.+): (.+) %(Level %d+ cap%)",                 { 69, 105 } },
    { "%[PartyFinder%] You have abandoned the duty",                    68 },
    { "%[PartyFinder%] You have an active duty",                       69 },
    { "%[PartyFinder%] You have a duty assignment",                    69 },
    { "%[PartyFinder%] You cannot leave the area",                     68 },
    { "%[PartyFinder%] Leaving will result in a forfeit",              68 },

    -- === HELM ===
    { "Harvesting is possible here if you have a (sickle)%.", { 2 } },
    { "You successfully harvest an* (" .. item .. ")%!", { 2 } },
    { "You harvest an* (" .. item .. "), but your (sickle) breaks.", { 2, 2 } },
    { "Your (sickle) breaks%!", { 2 } },

    { "Logging is possible here if you have a (hatchet)%.", { 2 } },
    { "You successfully cut off an* (" .. item .. ")%!", { 2 } },
    { "You cut off an* (" .. item .. "), but your (hatchet) breaks in the process%.", { 2, 2 } },
    { "Your (hatchet) breaks%!", { 2 } },

    { "Mining is possible here if you have a (pickaxe)%.", { 2 } },
    { "You successfully dig up an* (" .. item .. ")%!", { 2 } },
    { "You dig up an* (" .. item .. "), but your (pickaxe) breaks in the process%.", { 2, 2 } },
    { "Your (pickaxe) breaks%!", { 2 } },

    -- === Ventures ===
    { "You defeated a venture target%. %(Progress: %d+/%d+%)",                        69 },
    { "You defeated a dynamis venture target%. %(Progress: %d+/%d+%)",                69 },
    { "You accumulate %d+ special venture objective points*%. %(Progress: %d+/%d+%)", 69 },
    { "You have completed a special venture objective%. %(Progress: %d+/%d+%)",       69 },
    { "You have successfully completed the venture%.",                                69 },
    { "Your venture begins anew%.",                                                   69 },
    { "Your venture has expired%.",                                                   68 },
    { "Dynamis Prowess Increased %(%d+%/%d+%)%!",                                     69 },
    { "Dynamis Prowess Increased%!",                                                  69 },

    -- === Trials ===
    { "([A-Za-z]+ Trial) %[(" .. item .. ")%] (%d+/%d+) %((" .. item .. ")( in )(" .. item .. ")(%))", { 69, 2, 69, 86, 69, 105, 69 } },
    { "\129\154 Trial [A-Za-z0-9%_%'%.%: ]*Complete! \129\154", 69 },
    { "\129\154 Step Complete! \129\154", 69 },
    { "Your Adept trials have been reset%!", 68 },
    { "\129\158 Quest Cancelled", 68 },

    -- === Domain Invasion ===
    { "You have completed a domain invasion objective%. %(Progress: %d+/%d+%)",       69 },
    { "You have successfully completed a domain invasion rotation%! %(Total: %d+%)",  69 },
    { "You have successfully completed a domain invasion rotation!",                  69 },

    -- === Incursion ===
    { "New Objective%: Defeat", 69 },
    { "Incursion %[" .. item .. "%]", 69 },
    { "(%d+ pieces of missed currency) were stored at Garet%.", { 2 } },
    { "Bonus Objective%:", 69 },

    -- === Clamming ===
    { "You find an* (" .. item .. ") and toss it into your bucket%.", { 2 } },

    -- === Ephemeral Box (Crystal Warrior) ===
    { "You store (" .. item .. ") (x%d+) %(Total%: (%d+)%) ([A-Za-z]+) \129\168 ([A-Za-z]+)", { 2, 78, 109, 86, 105 } },
    { "You store (" .. item .. ") (x%d+) %(Total%: (%d+)%)", { 2, 78, 109 } },
    { "You store a (scroll of " .. item .. ") %(([A-Za-z ]+) \129\168 ([A-Za-z]+)%)", { 2, 86, 105 } },
    { "Ephemeral Box : I have (%d+) (" .. item .. ")%. %(([A-Za-z]+) \129\168 ([A-Za-z]+)%)", { 109, 2, 86, 105 } },
    { "You have already stored a (scroll of " .. item .. ")%.", { 2 } },
    { "You have a (scroll of " .. item .. ") currently in storage %(([A-Za-z ]+) \129\168 ([A-Za-z]+)%)", { 2, 86, 105 } },
    { "You scrap a (scroll of " .. item .. ") for (%d+ gil) %((Already stored)%)", { 2, 109, 105 } },

    -- === Summit of the Stars ==
    { "Now accumulating linkshell points for ([^%(]+) %(", { 2 } },
    { "[A-Za-z]+ gains (%d+ activity points)%.", { 2 } },
    { "Point Accumulation: (Disabled)", { 68 } },
    { "Summit Objective: Kill enemies of the ([A-Za-z%s]+) family%.", { 68 } },
    { "Obtained artifact: ([^%.]+)%.", { 71 } },
    { "You possess the following (Stronghold Artifacts):", { 71 } },
    { "(\x81\x9C)", { 2 } },  -- Green circle
    { "(\x81\x7E)", { 68 } }, -- Red X
    { "The (.+%a.+) crumbles to dust in your hands%." , { 71 } },
    { "Perhaps a ([^%?]+) could be placed here", { 71 } },
    { "The essence of ([A-Za-z%s%:%.]+) %[.+ has been forged onto the ([A-Za-z0-9%s%'%-_%.]+)%.", { 6, 2 } },
    { "%[S%], you will need an* ([^%?]+)", { 71 } },
    { "I can create this artifact in exchange for [one%d]+ ([A-Za-z%s]+), and", { 2 } },
    { "You already have an* ([A-Za-z%s]+). Come back", { 71 } },
}

return messages

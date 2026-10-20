ThatPet Ollama Extension
========================

WHAT IT DOES
  Makes ThatPet react to Ollama Desktop replies: Thinking while the model
  writes; working with the "Browsing the web…" bubble from a web search until
  the model starts writing the answer (it covers the minutes spent reading the
  results); Done when it finishes; the error animation if Ollama fails; back
  to idle if you stop a reply. It never reads or stores your chat text.
  ThatPet chooses the bubble from the tool name: web_search, web_fetch and
  browser_* tools -> "Browsing the web…".
  ThatPet ends an animation after 60 seconds without news, while Ollama's
  phases can last minutes, so during a reply the extension repeats the
  current event every 20 seconds (this does not change ThatPet's turn count).
  It starts by itself at every macOS login, together with ThatPet.

THE MENU BAR ICON (top right, next to ThatPet's cat)
  Two designs, chosen in the menu under Icon Style:
    ThatPet | Ollama   ThatPet's cat and Ollama's llama peeking over the same
                       edge, then a "+" (the two apps, connected)
    ThatPet +          ThatPet's cat with a "+" beside it
  The cat is identical to ThatPet's own and at the same height; both icons
  are read from the two apps without modifying them. Full icon = on;
  dimmed = off.
  It always sits right to the left of ThatPet's icon. To move them, hold Cmd
  and drag ThatPet's cat where you want it: macOS remembers the spot and the
  extension follows it within a few seconds.

  Click it to open the menu:
    switch               green = on, red = off (off stays off after a restart
                         until you turn it back on); orange while switching
    now                  during a reply: the current phase (Thinking,
                         Browsing the web, Writing the answer) and how long
                         it has been going, e.g. "2:31 (6:02 total)"
    ThatPet              Open / Not open
    Last reaction        the last animation sent to the pet, with the time
    orange warning       only when something is wrong, e.g. "Reply end not
                         detected" after an Ollama update: then check the log
    Open Ollama
    Show Log             the extension's log
    Open Project Folder  this folder
    Notify When a Reply Is Ready
                         a notification when a reply took 30 s or more and
                         Ollama is not in front (on by default). macOS refuses
                         system notifications to this app because it has no
                         developer certificate, so it uses AppleScript ones,
                         which macOS shows as "Script Editor": allow Script
                         Editor in System Settings > Notifications if needed.
                         Check: "ThatPet Ollama Extension.app/Contents/MacOS/
                         BridgeMenu" --notification-check
    Icon Style           ThatPet | Ollama or ThatPet +
    Quit Extension (Cmd+Q)  stops the extension until the next login

  After Quit Extension, double-click "ThatPet Ollama Extension.app" in this folder to
  bring the icon back before the next login.

WHERE EVERYTHING IS
  This folder (Documents > Ollama ThatPet Bridge) is the master copy:
    ollama_thatpet_bridge.py        the bridge
    autostart.py                    install, turn on/off, quit, remove
    ThatPet Ollama Extension.app    the menu bar icon
    menubar/                        the icon's source code (Swift)
    build_menu_app.sh               rebuilds the icon after a code change
    test-logs/                      logs from the tests of 2026-10-19

  The copies that run automatically (bridge and icon) live here, because
  macOS does not let background programs read the Documents folder:
    ~/Library/Application Support/OllamaThatPetBridge/
  Autostart:  ~/Library/LaunchAgents/local.ollama-thatpet-bridge.plist
              ~/Library/LaunchAgents/local.ollama-thatpet-bridge.menu.plist
  Log:        ~/Library/Logs/ollama-thatpet-bridge.log
  The Library folder is hidden in Finder: use Go > Go to Folder...
  (Shift+Cmd+G) and paste the path.
  Don't delete these files by hand: use "uninstall" (below).

COMMANDS (in Terminal)
  cd ~/Documents/"Ollama ThatPet Bridge"
  python3 autostart.py status      status and the last log lines
  python3 autostart.py stop        turn off (like the switch)
  python3 autostart.py start       turn on (like the switch)
  python3 autostart.py quit        stop until the next login (like Quit)
  python3 autostart.py install     after a change: update the copies in use
  python3 autostart.py uninstall   remove autostart, icon and copies (the log stays)

VERSIONS
  This folder is a git repository, so every change is saved:
    git log --oneline                    list of saved versions
    git checkout <version> -- <file>     bring back an old version of a file
  After changing the bridge or the icon: ./build_menu_app.sh (icon only),
  then python3 autostart.py install.

GOOD TO KNOW
  - Since ThatPet 0.4 "a disconnected agent never moves her": ThatPet ignores
    events from agents that are not connected in its menu. The extension
    talks to ThatPet as the "Hermes Agent", so install links it with
    ThatPet's own command (ThatPet connect hermes). That writes an inert
    plugin to ~/.hermes/plugins/thatpet (Hermes itself is not installed);
    ThatPet then lists Hermes as "needsUpdate" and accepts the events
    (verified: ThatPet's turn count moves for Hermes, not for unlinked
    agents). Uninstall removes it again. If a ThatPet update breaks the
    link, the menu shows "ThatPet · Open · not linked" and a "Reconnect to
    ThatPet" item.
  - ThatPet must never receive SessionEnd: it makes it quit (verified).
  - Only one bridge runs at a time: one started by hand while autostart is on
    refuses to start (the autostart one waits instead), so ThatPet never gets
    events twice.
  - The log is cut back to its last 200 KB when it passes 1 MB.
  - Ollama errors right after a web search ("No user query found in
    messages") are not caused by the extension. Web results are large (20-115
    KB of text, about 1 token every 2.5-3 characters) and when they don't fit
    in the context Ollama cuts the start of the chat, including your question.
    frob/qwen3.5-instruct:9b then crashes (its built-in template requires the
    question); qwen3.5:9b keeps working but on a 16 GB Mac it is 3-4x slower
    (MLX, 8.9 GB in memory). What works best here (tested 2026-10-20, Ollama
    0.40.6):
      * context length 32k in Ollama's Settings (about 1 GB of memory)
      * a new chat for searches: every message re-sends the whole chat,
        including old search results
      * keep frob for speed; switch to qwen3.5:9b only if a huge result
        still makes it fail
  - The pet goes back to idle after 15 minutes without any signal from
    Ollama (reading big search results can take minutes).

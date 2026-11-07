**ArcheAge Chronicles: Proton launch fix**  
For Linux players getting this Steam launch error:  
*The procedure entry point SystemTimeToTzSpecificLocalTimeEx could not be located in the dynamic link library KERNEL32.dll.*  
*\*\*NOTE\*\*: This is a fork of the original ArchAge Proton Fix, modified to add native support for fedora Silverblue, Bazzite, rpm-ostree, and steam flatpack.*  
![](data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAYAAABzenr0AAAABmJLR0QA/wD/AP+gvaeTAAAACXBIWXMAAA7EAAAOxAGVKw4bAAAAxElEQVR4nO1W0Q6AIAiE/v+bpaeaYyYc6NLVvbRm484DL1lEKAIRIWaG1zQ4IgAhsHCMJkc31BXQKmbtvF73iOkKQIvV8LbpFqAJ9Dvac2Z2iQ4N4UiYQ2gJ9G7g6TsupQw7UpHjefTCBCEmwueEaPAMhBzQBVDC+tkit2pOOQWXEx5H0gIy/ScK/Atq0os4k5ihHOilHJyYyyfhTIjIJg48idQ5EME6DrwlZB0HthaQcRG+FbeQuaZ/ewb2ScJfQBSe9p77EZ7a26s/yQAAAABJRU5ErkJggg==)  
Proton lets Windows games run on Linux. In the tested version, a Windows function for converting times between time zones is missing where the game expects to find it, blocking startup. This fix supplies that function using Proton's existing time-zone support.  
It uses a **private copy of Proton** without replacing shared Proton or patching the game or anti-cheat. Setup uses the included DLL; no compiler is needed. [Read how the fix works in plain language.](docs/how-it-works.md "docs/how-it-works.md")  
**Experimental:** Linux x86-64 with native Steam only. Tested on Fedora Silverblue, Bazzite; other setups are unverified. There is no guarantee of anti-cheat acceptance or account safety.  
**Install**  
1. Exit the game and use **Steam → Exit**, not just close the window.  
2. Open a terminal and run:
```
curl -fL --proto '=https' --proto-redir '=https' -o archeage-setup.sh \
  [https://raw.githubusercontent.com/nemo-sec/archeage-proton-fix/main/setup.sh](https://raw.githubusercontent.com/nemo-sec/archeage-proton-fix/main/setup.sh) && sh archeage-setup.sh
```

Run **without sudo**. Setup downloads the repo and DLL, checks requirements, and asks before installing system packages. The installer backs up the game's Windows settings/saves and never overwrites existing installations or backups.  
1. Follow the prompts. If available, choose `proton-cachyos-slr`, the tested base Proton.  
2. Start Steam and right-click **ArcheAge Chronicles**:  
  - Open **Properties → Compatibility**.  
  - Enable **Force the use of a specific Steam Play compatibility tool**.  
  - Choose **Proton ArcheAge TZ Fix (experimental)** and launch the game.  
If the option is missing, fully restart Steam. First-time shader compilation may take a while. Allow a few GB of free space for the Proton copy and backup.  
Missing curl? See [other download options.](#anchor-1 "#anchor-1")  
**Check dependencies**  
Without downloading the repo or installing packages:  
```  
sh archeage-setup.sh --check  
   
```  
Use `--check --install` or `--check --build` to check one group. Missing build tools do not prevent using the prebuilt DLL.  
If your script is named `setup.sh`, use `sh setup.sh --check`.  
**Undo**  
Exit the game and select your **original Proton version** under **Properties → Compatibility**. The added DLL is unused by the original Proton.  
Keep the backup until you are happy with the result. See [cleanup and restoration before restoring an older prefix over newer saves/settings.](#anchor-2 "#anchor-2")  
**More help**  
- [Troubleshooting](docs/troubleshooting.md "docs/troubleshooting.md")  
- [Build tools and source builds](#anchor-3 "#anchor-3")  
- [Manual installation and technical details](docs/advanced.md "docs/advanced.md")  
- [Report a problem](https://github.com/codecorsair/archeage-proton-fix/issues "https://github.com/codecorsair/archeage-proton-fix/issues")  
Original code and bundled shim/test binaries are [MIT licensed.](LICENSE "LICENSE")  

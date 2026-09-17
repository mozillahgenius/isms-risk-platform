# CHK-ENDPOINT-009 アプリ母集団候補（2026-08-16）

## 定義

v2定義の `unapproved_apps` は、`location_prefixes=["/Applications"]` と
`location_depth=1` により `/Applications` 直下のアプリだけを評価する。
`/System/Applications` と `~/Applications` は定義上の除外対象である。
`application_inventory=system_profiler_and_directory` により、下記の
`system_profiler` 出力と `/usr/bin/find` の列挙を突合する。差分は署名済み
`application_inventory_mismatches` 証跡へ残し、ディレクトリ側だけにあるアプリも
未承認名の判定へ含める。`include_hidden_bundles=true` によりドット始まりの `.app` も母集団に含める。
この一覧は承認済みリストではなく、実測した候補と差分の証跡である。

## 実測

コマンド:

```sh
/usr/sbin/system_profiler SPApplicationsDataType -detailLevel mini
```

今回のMacBook Proで `Location: /Applications/*.app` を抽出した結果は55パスだった。
これは追補§25の訂正値と一致し、以下の候補一覧を正とする。
比較用の逆向き検証では、`/System/Applications` まで母集団を広げると
violations rows が増加することをGoテストで確認する。

突合側のコマンドは次の固定argvである。

```sh
/usr/bin/find /Applications -name '*.app' -prune -print
```

追補§25の再取得時は `find` 65件（隠し8、可視57）、`system_profiler` 55件だった。
その後の同一MacBook Proでの実装検証時点では、`find` 66件（隠し9、可視57）となった。
追加の隠しバンドルが発生しているため、件数は時点依存の証跡として扱う。
現在のディレクトリ列挙にだけ存在する差分は次のとおりで、収集器はこれを黙って捨てず拒否する。

- 承認済みだが `system_profiler` にない: `/Applications/Safari.app`
- 未承認で `system_profiler` にない: `/Applications/xsbug.app`
- `include_hidden_bundles=true` により母集団に含めるが `system_profiler` にない隠しバンドル:
  `.routine-console-backup-*.app`（検証時点9件）

したがって、`system_profiler`側だけを採用してCHK-ENDPOINT-009を緑にすることはできない。
差分がある収集結果には、差分の種別とアプリ名が署名済み証跡として残る。

## 候補一覧

1. `Numbers` — `/Applications/Numbers Creator Studio.app`
2. `Pixelmator Pro` — `/Applications/Pixelmator Pro Creator Studio.app`
3. `Pages` — `/Applications/Pages Creator Studio.app`
4. `Compressor` — `/Applications/Compressor Creator Studio.app`
5. `Motion` — `/Applications/Motion Creator Studio.app`
6. `Keynote` — `/Applications/Keynote Creator Studio.app`
7. `MainStage` — `/Applications/MainStage Creator Studio.app`
8. `Final Cut Pro` — `/Applications/Final Cut Pro Creator Studio.app`
9. `LINE` — `/Applications/LINE.app`
10. `Cursor` — `/Applications/Cursor.app`
11. `Visual Studio Code` — `/Applications/Visual Studio Code.app`
12. `Slack` — `/Applications/Slack.app`
13. `Tailscale` — `/Applications/Tailscale.app`
14. `Routine Console` — `/Applications/Routine Console.app`
15. `GarageBand` — `/Applications/GarageBand.app`
16. `iMovie` — `/Applications/iMovie.app`
17. `Keynote` — `/Applications/Keynote.app`
18. `Numbers` — `/Applications/Numbers.app`
19. `Pages` — `/Applications/Pages.app`
20. `マイナポータル` — `/Applications/MynaPortalApp.app`
21. `Qwen` — `/Applications/Qwen.app`
22. `Moshi` — `/Applications/Moshi.app`
23. `VoiceInk` — `/Applications/VoiceInk.app`
24. `Vrew` — `/Applications/Vrew.app`
25. `Brother iPrint&Scan` — `/Applications/Brother iPrint&Scan.app`
26. `Trezor Suite` — `/Applications/Trezor Suite.app`
27. `CyberGhost VPN` — `/Applications/CyberGhost VPN.app`
28. `BambuStudio` — `/Applications/BambuStudio.app`
29. `Google Chrome` — `/Applications/Google Chrome.app`
30. `Loom` — `/Applications/Loom.app`
31. `Ghostty` — `/Applications/Ghostty.app`
32. `Antigravity` — `/Applications/Antigravity.app`
33. `Blender` — `/Applications/Blender.app`
34. `Obsidian` — `/Applications/Obsidian.app`
35. `Google Drive` — `/Applications/Google Drive.app`
36. `Google Docs` — `/Applications/Google Docs.app`
37. `Google Sheets` — `/Applications/Google Sheets.app`
38. `Google Slides` — `/Applications/Google Slides.app`
39. `Claude` — `/Applications/Claude.app`
40. `CapCut` — `/Applications/CapCut.app`
41. `ScanSnap Home` — `/Applications/ScanSnapHomeMain.app`
42. `LibreOffice` — `/Applications/LibreOffice.app`
43. `Microsoft Teams` — `/Applications/Microsoft Teams.app`
44. `Meet Assistant` — `/Applications/Meet Assistant.app`
45. `Microsoft OneNote` — `/Applications/Microsoft OneNote.app`
46. `Microsoft Outlook` — `/Applications/Microsoft Outlook.app`
47. `Microsoft Excel` — `/Applications/Microsoft Excel.app`
48. `Microsoft PowerPoint` — `/Applications/Microsoft PowerPoint.app`
49. `Microsoft Word` — `/Applications/Microsoft Word.app`
50. `zoom` — `/Applications/zoom.us.app`
51. `Gemini` — `/Applications/Gemini.app`
52. `Windows App` — `/Applications/Windows App.app`
53. `OneDrive` — `/Applications/OneDrive.app`
54. `Microsoft Defender` — `/Applications/Microsoft Defender Shim.app`
55. `ChatGPT` — `/Applications/ChatGPT.app`

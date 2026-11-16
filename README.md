# Preflight Teams Priority — experimental single-window build

This small project builds a modified Slippi Dolphin 3.6.4 on GitHub's Windows
runner. It contains source changes and a checksum-bound patch recipe. It does
not contain a Melee ISO, Preflight DAT/DOL files, or Slippi account credentials.

The game adapter adds **Play singles → Unranked / Direct** to Preflight's pause
menu. Teams must be queued first. When every Teams peer connects, the modified
emulator ends singles and the game adapter attempts to enter Teams in the same
window. This is an experimental first implementation; successful compilation
and simulated tests do not establish live matchmaking compatibility.

## Build

1. Create a free GitHub account, verify its email, and create a new **public**
   repository named `preflight-teams-priority`.
2. On the empty repository page, click **uploading an existing file**. Open the
   extracted kit folder, select ALL its contents, and drag those items into the
   upload page. Keep the folder structure. Click **Commit changes**.
3. Open **Actions → Build Windows Teams Priority test**. The upload should
   trigger a run; otherwise click **Run workflow**. No signing secrets are used.
4. After a green run, open it and download **Slippi-Teams-Priority-Windows-test**
   under **Artifacts**. Extract both the artifact wrapper and the test ZIP inside.
5. Follow the included `TESTING.txt`. Never upload your ISO or `user.json` here.

If the run fails, share the Actions run URL. A failed build does not produce a
playable release. GitHub may require account verification before running Actions.
For a public repository, standard hosted Windows runners are free under GitHub's
current Actions policy; do not enable paid or larger runners for this project.

## Source and reproducibility

`parallel-queue/dolphin.patch` applies to project-slippi/Ishiiruka tag v3.6.4
(commit e7711b104b339a99385f2bb12b472d46140a7bc7). It includes the native changes,
PowerPC adapter source, module builder and isolated tests. The workflow fetches
that upstream source and its pinned submodules, applies the patch, tests the
small Windows components, and builds the ordinary WX frontend.

The original Preflight mod is by Aitch. This project is an independent
experimental integration, not an official Preflight or Slippi release. We have
compiled original-module exports rather than Aitch's original source tree.
The adapter source is GPLv2+; the Dolphin patch is subject to Dolphin's license.

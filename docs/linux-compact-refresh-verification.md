# Linux0.4.5 — приёмка

Status: released 2026-10-08 as linux-v0.4.5. Accepted source19440ee112f164b411bf4715d6fa65077a272c48; full evidence below. Earlier pending/failure entries are chronological history.

## Baseline evidence

Existing Linux CI [37723616264](https://github.com/ArrivaRUS/claude-codex-limits/actions/runs/37723616264) succeeded at1078ddbe058196204265a0bc565ff591cb8ca45c (Linux0.4.4). Its192PNG downloaded for visual reference to /private/tmp/ccl-linux-baseline-57m2zmw1. This is not validation of new0.4.5 code. Prior release linux-v0.4.4 has a DEB asset with SHA2565dc4a6b95e1780e36ee16fa7f4bc4eda21d4a4eaaf83a0f212527a00fc9c1ca5.

## Boundaries

Scope includes existing accepted manual-refresh contract; DeveloperComplex handles provider admission/results and retry metadata, with CodeReviewer and SecurityAnalyst before runtime. Underlying Auto progression/endpoints/credential stores remain. CodeReviewer checks functional correctness and exactCI isolation; SecurityAnalyst reviews the changed auth/result boundaries before execution/release. ExistingCI uses dedicated synthetic home, no network exceptloopback, nohostmounts/sessionbus/credentials, offscreenPyQt; fullsuite must have0skips. CI evidence/DEB will be downloaded for QA and independent design review. LiveALSE/KDE/Fly, userkeyring and actual remoteinstallation are not established by container tests. No realusercredentials/logs/API during tests.

Publication: linux-v0.4.5 with verifiedDEB, --latest=false. LatestmacOS remainsv3.2.7. No packageinstallation on thisMac is intended.

## UI author handoff

DesignEngineer completed boundedUI/version at fc794dc with AST/compileinmemory/diffcheck PASS, noexecution. Prebackend UI hashes: panelfab798c02bc228b718e2ff9cb9a3c42638b66603c353d39303e44e907f9dfb14; app11192fd868d94b24ae5f8d4d4e5844263dc15bbdf745b40d1cc001ed4e27ab69; version8f2d78cb13dbcb9e290b005a4daea7865d0003a6fcb2433abeda82153be00b6d. Authorclosed; app/panelownership handed sequentiallytoDeveloperComplex foracceptedmanualrefreshintegration. Thesehashesarenotfinalreleasefreeze.

## Preliminary security snapshot

Separate SecurityAnalyst assigned early phase1 review at immutable /private/tmp/ccl-linux-security-phase1-3d7cvude: quota859180264025132db4a5e773b21009a5d0884c702d7a89e93e5494171de677f8, limitsa27c98837e812d3479bda9da78d51dd94b11f4ae767bbfb7e2dd4032e7304679. App/testimplementationstillinprogress; thissnapshot cannotauthorizefinalCI orrelease. No runtimeexecuted.

## Resume after quota interruption

DeveloperComplex, Tester and SecurityAnalyst stopped on account usage limit before final freeze; partial source/tests remained in the working checkout. User explicitly requested continuation. All three resumed in the same approved models/roles; no model substitution. New runtime/CI still not executed.

## Phase1 security findings

Independent SecurityAnalyst found no new confirmedP1/P2 in phase1, but inheritedP2 credential reread fallback to first snapshot can resurrect deleted/overwrite newer CLI credentials. Assigned bounded fail-closed read/missing/corrupt protection and pending preservation toDeveloperComplex, synthetic tests toTester. Existing external CLI read–replace race cannot be claimed atomic without cooperation; final limitations must distinguish it. VerylargefiniteRetryAfter is accepted by puredeadlinecontract; GUI timer/countdown must remain bounded without shortening the realserverdeadline. FinalGUI/isolationreview still pending.

## Production freeze 1

DeveloperComplex FINAL completed UI integration/manual behavior and bounded credential reread fix. Source hashes: quota57c6d652, limits7becbbbb, app80177d9, panel761d04d (full in /private/tmp/ccl-linux-freeze-4qjo_pgx/manifest.json). Author staticPython3.7grammar/compileinmemory/ASTchecks PASS; no runtime. Independent CodeReviewer and SecurityAnalyst assigned thisimmutableproductionfreeze. Testeralignment stillpending; tests inthissnapshotarenotfinal. Remaining externalCLIread–replace window and memory-onlypending explicit incontract.

## Final production security review — freeze1

SecurityAnalyst (Astra/high) PASS on /private/tmp/ccl-linux-freeze-4qjo_pgx exact production hashes; no newP1/P2. Earlier fail-open credential-reread fallback closed, pendingidentity retained, newerpairwins. Perproviderflight/generation fence precedes model/cache/history, queuedmainthreadcompletion; retrydeadlinepersisted andQt timer rechecks atmost60s withboundeddate/countdownformatting. Newrecoveryactionsdisplayinstructions only; noimplicitlogin/rawsecretdataoutput.

Explicitlimits: externalCLIread–replace race, RAM-onlypending lostonprocessdeath, deadlinepersistenceafterstatewritefailure notguaranteed; disabling doesnotcancelalreadyrunningtransport/tokenwriteback. ValidhugeRetryAfter intentionallyhonored. Staticreviewonly; finaltestisolation/runtime andvisual/packageacceptance pending.

## Freeze1 code review findings

Independent CodeReviewer found2P2: wall-clock rollback extends local30sguard and loses futurelast_attemptnormalization; shared startupalarmbaseline allows firstresponse of secondprovider tosound reset whileappwasoff. Assigned bounded monotonic/localclock handling and perproviderbaseline fix toDeveloperComplex, independent tests toTester. Freeze1notacceptedforrelease. Otherrequestedbehavior traced; SecurityPASS remains scopedtoreviewedauth/resultboundarypendingdelta.

## Production freeze2

Author completed bounded2P2fix: required injectedmonotonic time forlocalguard (restartrestore<=30s), wallfuturepollanchorcorrected, perproviderfresh startupalarmbaseline. quotae79f6a8ac2d5f390c1233709d6b03726447ec8334da8ef675fdfd4f0605d186a; app25d030ff08fbae5f48e512b34c3305597af31ca347c0cca6d8c08b6a09b8df3c. limits7becbbbb/panel761d04df/polling byteidenticalfreeze1. Immutable /private/tmp/ccl-linux-freeze-pd0jqga4. NarrowCode/Securitydelta reviewing; Testerfinalalignment pending; no runtime.

Freeze2 independentSecuritydelta PASS: onlyquota/app productionchanged, monotoniclocalguard doesnotalterserverdeadline, fence/cache boundariespreserved, perproviderbaseline checked. PreviousauthPASS/limitationscarryforward. No runtime/testisolationacceptance claimed.

Freeze2 CodeReviewer productionPASS: bothP2closed, no newP1/P2 in narrowdelta. ASTPython3.7 2/2 and exactsource/manifestchecks passed; unchangedauth/panelnotre-reviewed. Independentruntime/tests/GUI/packageacceptance stillpending.

## Final test preparation

Tester completed phase2: 43 manual-refresh tests plus legacy/UI fixture alignment. All40 test Python files passed static Python3.7 grammar and compile-in-memory checks; no project import/runtime. Final test snapshot /private/tmp/ccl-linux-freeze-c3ulwvck, review.diff SHA256 0c25282658dc14b5e6c014e62856cb159e52d38b8abdf63a7e461542d0aa489c. Independent isolation-only review assigned before CI.

Tester found a further credential-reread edge case: empty current credential block was treated as superseded and discarded pending rotation. DeveloperComplex assigned narrow fail-closed correction, with existing regression expectations retained. Production freeze2 acceptance does not cover this pending delta.

## Production freeze3

Narrow credential-block fix completed: incomplete identity at initial read or write-back remains pending without write; complete changed pair wins. Independent SecurityAnalyst production security/correctness delta PASS. Only limits.py changed under linux/ccl from freeze2, SHA256 0f47d6663066de9690cab812dd8f127ab77635de1d47981197d0200a2a5f48d5; contract f0a0a889a87ae3916608faf44cf176aa99f394aaf2f1c6b87d6cf0358f5b6b67. Snapshot /private/tmp/ccl-linux-freeze-c08fgctf. Existing tests cover empty block and changed pair; partial-field type/whitespace variants are not separately exercised. This is a test-evidence limitation, no confirmed remaining production defect. Prior review boundaries carry forward; CI pending.

## Runtime gate

Independent CodeReviewer isolation-only PASS for final c08fgctf: all45 test/workflow/packaging entry files match; isolation digest8ffaf9d4821d6014b601c7142e291b033eb6d954a98cea302009add29e0f79cc. Authorized only existing no-network/no-mount synthetic-user GitHub CI with mandatory preflight. No local host runtime authorized or performed. Production freeze2 Code PASS plus freeze3 Security/correctness delta PASS complete the static gates.

## CI attempt1

Source2d224e041d7b85a029dc1ccd723c8c595d09165e, run37728899968. Isolation preflight confirmed uid10001, synthetic/home/ccltest, loopback-onlynetwork, noDBus/credentialenv. Suite356 tests / 11failures / 1error / 0skips; noDEB produced. Failures include obsolete auth/footer copy expectations, floating-point cancellation tolerance and rollback synthetic-worker fixture. Tester assigned diagnosis and bounded corrections without masking production failures. Actual rendered PNG evidence downloaded to /private/tmp/ccl-linux-ci1-evidence and assigned independent visual review; this run is not a successful release gate.

## CI1 diagnosis and test correction

Tester traced all CI1 diagnostics to obsolete copy assertions or synthetic-clock setup, without production edits. Tests now verify new compact recovery ownership and unknown-time tooltip, allow1µs wall-projection rounding while retaining strict29.999/30s admission, and retain the original monotonic epoch in rollback setup. Test hashes: auth82635dbd9f9fe2f3b8af6e5df7555f519dc4045d5b4d103027c17e1ab01fcaeb; manual7765b8191169a23868b0ac59598aec70a629350c058fc37950d99441d8176a67. Narrow independent review assigned before rerun. Production exact2d224e0 remains unchanged.

## CI1 delta review and visual findings

CodeReviewer accepted test corrections and bounded candidate docs at zfnocjh7: test-delta/isolation/docs PASS, production unchanged2d224e0. Isolation digestb05f7a8e8a48292e40bbefd3469986e718660ab28d83c325d77fa1a77eda04c4. CI rerun not yet started because independent DesignReviewer found a new UI issue.

DesignReviewer visually inspected40 currentPNG (26compact+14auth),7Linuxbaseline and2acceptedmacreferences: wholepanel/32ptfeedback/4h/Auto/forecastcomposition accepted, but overallFAIL: P2 recoverylink contrast4.29:1 on Advancedgray; P3 repeatedNotsetup inmissingfooter. Assigned boundedpanel fixes toDesignEngineer. AdditionalrepresentativePNG forfixedintervals,equal/differentAuto,local/serverwait,partialinflight,CodexonlySimple andnamedBreeze/Fusion assignedTester; existinginputsafetyboundariesretained. ActualnativeALSE/HiDPI/livekeyboard remainunverified.

## Visual correction

DesignEngineer changed only panel.py(+1/-3): footer actions now use existing LINK107,158,245 (calculated5.28:1 ongray43); missing footer retains Data— without repeatedNotsetup. NewpanelSHAee19fe2161120bc26b20d8d7833212236de97552aa3e25f13baeda265407bd09. Allotherfunctions/classes preserved by ASTcomparison; runtime/actualcontrast in newPNG stillpending.

## Supplementary image fixtures

Tester added30representativePNG scenarios in two existing UI test files: fixed15/60/240, equalAuto/30+60/swappedproviders,30sguard/90sRetryAfter,independentpartialcompletion,Codex-onlySimple; namedFusion/Breeze styles. Previousauto-ui tests produced QImage but didnot save it; now save through existingCCL_PREVIEW_DIR. Prior26compact retained, plannedtotal56new/currentcompact-auto images. Staticgrammar/compileinmemory and unique-name checks PASS; no runtime. Finalsnapshot s4o8lp5k assigned narrow CodeReviewer/isolation review beforeCI2.

## CI2 gate

Narrow CodeReviewer found missing LINK in extracted-function test namespace; Tester added only syntheticLINK='link', _freshness_env SHAde2e3cca1c351e02d1906752ad0167b545768dec51d7d82eef295ccfbc266d3f. Reviewer confirmed onlythisdelta vs s4o8lp5k and closedP2. Bounded functional + isolation PASS forCI2; same outerCIconditions.

## CI2 success

Exactsource19440ee112f164b411bf4715d6fa65077a272c48; [run37730102871](https://github.com/ArrivaRUS/claude-codex-limits/actions/runs/37730102871) succeeded.358tests /0failures /0errors /0skips. Preflight:uid10001,synthetic/home/ccltest,loopbackonly,noexternalinterface,noDBusorcredentialenv. Artifacts downloaded to /private/tmp/ccl-linux-ci2-artifacts. DEB SHA25699acde08c13b7c66335718554ec09af087253e3e3b58113e720e3a67dfc71b10. Independent packagedQA and visualdelta review assigned; not yet accepted or published. Two actualCI referencePNG copied into docs/linux-compact-refresh-auto4h-ru.png and docs/linux-compact-refresh-simple-ru.png.

## Independent visual acceptance

DesignReviewer CI2 delta PASS:37actualPNG visually inspected (30newscenarios+7P2/P3),26CI1->CI2pixelcomparisons. Contrast measured5.2823:1RU /5.5002:1EN; missingduplicategone. Fixed15/60/240,Autoequal30/30+60bothpermutations,localguard30s,server90sdisplay2min,partialcompletionbothdirections,CodexonlySimple,Fusion/Breeze accepted.18/26priorcompactimagesidentical;4errorchangedonlyactioncolor,4missingchangedfooter,all26dimensionsretained. Exactsource19440ee; panelSHAee19fe21. LiveALSE/HiDPI/interactivefocus/tooltip/keyboard remainunverified, no concrete blocker. Code/security/isolation conclusions remain valid; packageQA pending.

## Independent packaged QA

QA report /private/tmp/ccl-linux-qa-final/REPORT.md: bounded static packagePASS,202assertions/0failures,19Python3.7grammarchecks. DEB621880bytes;39regularfiles/18directories,34payloadfiles match exactsource19440ee blobs; generated5payload+3controlentries match buildrecipe. Version0.4.5,archall,dependsPython>=3.7/PyQt5/dbus; permissions/installpaths and existingupgradecontract accepted. No usercredentials/cache/tests/buildjunk inallowlistedpayload. CIjson358/0/0/0 and184PNGinventory checked. Liveinstall/ALSE/nativekeyring/audio/UI notrun.

QA observed coordinator-owned verification.md and2referencePNG made workingtree dirty while exactsource/packageinputs remainedunchanged. These expected acceptance artifacts are committed bycoordinator beforeclean-tree verification; no packagecontent defect or rebuild required. SameDEBSHA99acde08c13b7c66335718554ec09af087253e3e3b58113e720e3a67dfc71b10 independentlyconfirmed.

## Publication and final integration

[Linux0.4.5](https://github.com/ArrivaRUS/claude-codex-limits/releases/tag/linux-v0.4.5) published with exact acceptedCI DEB, target19440ee112f164b411bf4715d6fa65077a272c48 and --latest=false. Publicasset downloaded to /private/tmp/ccl-linux-public-045, cmp identical; SHA25699acde08c13b7c66335718554ec09af087253e3e3b58113e720e3a67dfc71b10 and GitHubAPI digest agree;621880bytes, stateuploaded. APIreleases/latest remainsv3.2.7. NoLinuxinstallation performed onMac/ThinkPad.

Coordinator committed expected QA metadata/2referencePNG in482a903; subsequentgitstatusshort wasempty, closing QA workingtree-cleanliness finding withoutchangingpackageinputs. Main fast-forwarded53bb5bf→482a903 beforepublication. Release tag targets acceptedsource ratherthanmetadata. Final release-status docs are a separate metadata update.

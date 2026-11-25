# Migrasi report Power BI antar-workspace

Script [Migrate-PowerBIReports.ps1](Migrate-PowerBIReports.ps1) memakai **Power BI REST API Clone Report**, bukan download/upload PBIX. Mode **Move** menambahkan Delete Report setelah verifikasi. Kedua workspace harus sudah ada, berada dalam tenant yang sama, dan memiliki **capacityId yang sama**. Script tidak membuat workspace atau mengubah capacity.

## Pilihan Copy atau Move

| Mode | Report tujuan | Report asal |
| --- | --- | --- |
| `-Mode Copy` (default) | Dibuat dan diverifikasi | Tetap ada |
| `-Mode Move` | Dibuat dan diverifikasi | Dihapus setelah **semua report terpilih** lolos verifikasi API dan pemeriksaan ulang sumber |

Keduanya hanya **preview** tanpa `-Apply`. Move adalah **clone + delete**, bukan perpindahan atomik yang mempertahankan ID. Jika terjadi kegagalan, sebagian salinan/penghapusan bisa sudah selesai dan dicatat di state.

## Diagram alur aktivitas

Alur berikut mengikuti [Migrate-PowerBIReports.ps1](Migrate-PowerBIReports.ps1), termasuk penggunaan state saat proses dijalankan ulang.

```mermaid
flowchart TD
    START([Mulai]) --> INPUT["Baca workspace asal/tujuan, ReportIds, Mode dan Apply"]
    INPUT --> INIT["Siapkan StatePath<br/>Ambil lock jika Apply aktif"]
    INIT --> LOGIN["Cek modul autentikasi<br/>Login pengguna interaktif ke Power BI"]
    LOGIN --> WORKSPACES["GET daftar workspace dan resolve nama atau ID"]
    WORKSPACES --> CAPACITY{"Workspace berbeda, akses tulis,<br/>dedicated capacity dan capacityId sama?"}
    CAPACITY -->|Tidak| STOP["Berhenti dengan error<br/>Tinjau hasil dan state sebelum melanjutkan"]
    CAPACITY -->|Ya| STATE["Baca dan validasi state<br/>GET daftar report asal dan tujuan"]
    STATE --> SELECT["Pilih semua report atau ReportIds<br/>Sertakan resume Move yang sumbernya sudah hilang"]
    SELECT --> PREFLIGHT{"Jenis report, nama, binding<br/>dan state valid tanpa konflik?"}
    PREFLIGHT -->|Tidak| STOP
    PREFLIGHT -->|Ya| PLAN["Tampilkan rencana dan peringatan<br/>Semantic model tetap di lokasi asal"]
    PLAN --> APPLY{"Apply aktif?"}
    APPLY -->|Tidak| PREVIEW["Preview saja<br/>Tidak membuat atau menghapus report"]
    PREVIEW --> CLEANUP["Lepaskan lock jika diambil"]
    APPLY -->|Ya| TARGET["Proses report tujuan berikutnya"]
    TARGET --> CLONE{"Perlu clone baru?"}
    CLONE -->|Ya| REQUEST["Simpan status CloneRequested"]
    REQUEST --> POST["POST Clone ke workspace tujuan<br/>Jangan ulang POST otomatis"]
    POST --> CREATED["Simpan targetReportId<br/>dan status Created"]
    CLONE -->|Tidak, sudah tercatat| VERIFY
    CREATED --> VERIFY["GET report tujuan<br/>Periksa ID, nama dan datasetId"]
    VERIFY --> VALID{"Identitas dan binding cocok?"}
    VALID -->|Tidak| STOP
    VALID -->|Ya| SAVETARGET["Simpan hasil verifikasi tujuan<br/>Pertahankan status penghapusan saat resume"]
    SAVETARGET --> MORETARGET{"Masih ada report tujuan?"}
    MORETARGET -->|Ya| TARGET
    MORETARGET -->|Tidak| MODE{"Mode Move?"}
    MODE -->|Tidak, Copy| COPYDONE["Copy selesai<br/>Semua report asal tetap ada"]
    COPYDONE --> CLEANUP
    MODE -->|Ya| RECHECK["GET ulang semua report asal yang masih ada<br/>Periksa ID, nama dan datasetId sebelum DELETE pertama"]
    RECHECK --> SOURCEVALID{"Semua sumber yang diperiksa cocok?"}
    SOURCEVALID -->|Tidak| STOP
    SOURCEVALID -->|Ya| SOURCE["Proses report asal berikutnya"]
    SOURCE --> DELETED{"State sudah SourceDeleted?"}
    DELETED -->|Ya| CONFIRM
    DELETED -->|Tidak| DELETESTATE["Simpan status DeleteRequested"]
    DELETESTATE --> PRESENT{"Sumber masih ada dalam rencana?"}
    PRESENT -->|Ya| DELETE["DELETE report asal<br/>Jangan ulang DELETE otomatis"]
    PRESENT -->|Tidak, resume| CONFIRM
    DELETE --> CONFIRM["GET report asal untuk memastikan penghapusan"]
    CONFIRM --> ABSENT{"HTTP 404?"}
    ABSENT -->|Tidak, masih ada atau error lain| STOP
    ABSENT -->|Ya| SAVEDELETE["Simpan status SourceDeleted"]
    SAVEDELETE --> MORESOURCE{"Masih ada report asal dalam rencana?"}
    MORESOURCE -->|Ya| SOURCE
    MORESOURCE -->|Tidak| MOVEDONE["Move selesai<br/>Report asal terhapus, model tetap di lokasi asal"]
    MOVEDONE --> CLEANUP
    STOP --> CLEANUP
    CLEANUP --> END([Akhir proses])
```

- Kegagalan login, request API, atau penulisan state pada aktivitas mana pun menghentikan proses dan tetap melepaskan lock. GET tertentu dapat diulang sesuai aturan retry; POST/DELETE tidak diulang otomatis.
- State `CloneRequested` yang belum pasti menghentikan preflight, bukan menyebabkan clone ulang. Report tujuan yang sudah tercatat diverifikasi kembali.
- **Semua tujuan harus lolos verifikasi API sebelum penghapusan pertama.** Pada resume Move, sumber yang sudah hilang dikonfirmasi melalui GET tanpa DELETE ulang.
- Penghapusan Move dilakukan satu per satu, bukan satu transaksi. `Verified` bukan bukti visual/data/RLS benar; gunakan Copy dahulu untuk uji pengguna sebelum Move.

## Yang dipindahkan dan yang tidak

- Report dibuat sebagai **salinan baru** di workspace tujuan, dengan nama yang sama tetapi ID dan URL baru.
- **Semantic model/dataset tidak disalin.** Report baru tetap menggunakan model asli, termasuk model yang sebenarnya berada di workspace ketiga. Shared dataset/reference dapat muncul di workspace tujuan; ini bukan salinan data.
- **Copy** tidak menghapus report asal. **Move** menghapus hanya report asal yang dipilih; model dan workspace asal tidak pernah dihapus.
- Workspace access, sharing, app/audience, subscriptions, personal bookmarks, dashboard tiles, folder, endorsement dan sensitivity labels **tidak dimigrasikan atau diverifikasi oleh script**. Tinjau dan konfigurasi di tujuan sesuai kebijakan organisasi.
- Refresh schedule, credentials dan gateway model tidak diubah karena model tetap digunakan. Pastikan pengguna tujuan memiliki akses ke model; capacity yang sama **tidak otomatis memberikan izin**.
- Clone API dapat mengubah report live connection menjadi direct binding ke dataset. Uji hasilnya.
- Script ditujukan untuk Power BI report biasa. RDL/paginated atau report tanpa `datasetId` akan menghentikan preflight. Gunakan `-ReportIds` untuk memilih hanya report biasa.
- PBIR tidak dibaca atau diubah oleh script. Format report ditangani layanan Clone API.

**Jika workspace lama harus dihapus**, semantic model beserta dependensinya harus dimigrasikan terlebih dahulu lewat alur terpisah, kemudian report dihubungkan ke model tujuan yang kompatibel. Mode Move pada script ini **tidak** memindahkan model atau membuat workspace lama aman untuk ditutup.

## Prasyarat

1. **PowerShell 7+** (`pwsh`), bukan Windows PowerShell 5.1.
2. **MicrosoftPowerBIMgmt.Profile 1.3.84+**, sesuai pembaruan konfigurasi sign-in Microsoft. Tidak perlu Azure CLI, client ID, client secret, atau service principal.
3. Akun pengguna memiliki Pro/PPU untuk copy antar-workspace; Fabric capacity yang sama tidak menghapus syarat ini. Siapkan minimal Contributor di workspace asal/tujuan dan Build pada model yang digunakan.
4. API pengguna memakai scope `Workspace.Read.All` (list workspace), `Report.Read.All` (list/verifikasi report), dan `Content.Create` (clone), atau scope read/write yang sesuai. **Move membutuhkan `Report.ReadWrite.All` untuk penghapusan**. Modul Microsoft menangani permintaan token melalui aplikasi first-party Power BI; kebijakan consent/Conditional Access tenant tetap berlaku.
5. Login harus memakai **akun pengguna organisasi yang memiliki akses ke kedua workspace**, bukan sekadar akun yang bisa login. Script mengecek akses tulis workspace, tetapi Build permission dan izin API tetap ditegakkan layanan. MFA/Conditional Access mengikuti kebijakan organisasi.

Script menjalankan **`Connect-PowerBIServiceAccount` dalam mode User (interaktif)**, lalu mengambil header Bearer melalui **`Get-PowerBIAccessToken`** sebelum setiap request. Modul menangani sesi/token Power BI; tidak ada penambahan prefix Bearer dua kali. Token, password, dan kode MFA tidak ditulis ke state atau dicetak.

## Menjalankan

Jalankan dari PowerShell 7 di folder script.

### 1. Pasang modul autentikasi sekali saja

```powershell
Install-Module MicrosoftPowerBIMgmt.Profile -MinimumVersion 1.3.84 -Scope CurrentUser -Force
```

Jika PSGallery belum terdaftar, jalankan `Register-PSRepository -Default` dahulu. Setelah update modul yang sudah pernah dimuat, gunakan sesi PowerShell baru.

**Tidak perlu menjalankan `az login` atau login manual sebelum script.** Saat script dijalankan (termasuk preview), prompt **Sign in** Microsoft akan muncul. Pilih akun kantor yang punya akses ke workspace asal dan tujuan, lalu selesaikan MFA bila diminta. Jangan memasukkan password atau kode MFA ke chat/script. Login dibatalkan/gagal akan menghentikan proses sebelum request migrasi.

Autentikasi ini membutuhkan sesi pengguna interaktif; bukan mode unattended/service principal. Endpoint script saat ini untuk cloud **Public**. Script tidak menutup sesi Power BI dengan logout otomatis agar tidak mengganggu penggunaan lain di proses PowerShell yang sama.

### 2. Cek rencana tanpa membuat report

```powershell
.\Migrate-PowerBIReports.ps1 `
    -SourceWorkspace "Workspace Lama" `
    -TargetWorkspace "Workspace Baru"
```

Nama dicocokkan secara utuh, bukan pencarian sebagian. Jika nama workspace duplikat, gunakan workspace ID dari URL `https://app.powerbi.com/groups/<WORKSPACE-ID>/...` sebagai nilai parameter yang sama.

Preview mengambil daftar workspace/report, mengecek capacity dan konflik, lalu menampilkan `sourceReportId`, `datasetId`, dan tindakan. **Belum ada perubahan di Power BI.** Build permission dan keberhasilan render tidak dapat dipastikan hanya dari preflight ini.

### 3. Salin dan verifikasi

```powershell
.\Migrate-PowerBIReports.ps1 `
    -SourceWorkspace "Workspace Lama" `
    -TargetWorkspace "Workspace Baru" `
    -Mode Copy `
    -Apply
```

Pilih report tertentu, misalnya uji satu report terlebih dahulu:

```powershell
.\Migrate-PowerBIReports.ps1 `
    -SourceWorkspace "Workspace Lama" `
    -TargetWorkspace "Workspace Baru" `
    -ReportIds "<REPORT-ID-1>", "<REPORT-ID-2>" `
    -Apply
```

Ganti placeholder sebelum menjalankan. Tanpa `-ReportIds`, semua report asal dipilih. Semua konflik/jenis report diperiksa sebelum clone pertama.

### 4. Move: salin, verifikasi, lalu hapus report asal

```powershell
.\Migrate-PowerBIReports.ps1 `
    -SourceWorkspace "Workspace Lama" `
    -TargetWorkspace "Workspace Baru" `
    -Mode Move `
    -Apply
```

Hilangkan `-Apply` untuk preview Move, atau tambahkan `-ReportIds` untuk membatasi report. **Dengan `-Mode Move -Apply`, Anda mengizinkan penghapusan report asal** setelah verifikasi API; tidak ada konfirmasi interaktif tambahan.

Rekomendasi aman: jalankan **Copy terlebih dahulu**, uji visual/data/RLS dan siapkan URL/app tujuan, lalu jalankan **Move dengan state dan pilihan report yang sama**. Script menggunakan salinan yang sudah tercatat, bukan membuat ulang. Jangan mengedit report atau mengubah binding selama proses cutover; API tidak menyediakan transaksi lintas-workspace atau pendeteksian seluruh perubahan isi visual.

## State, kegagalan, dan menjalankan ulang

- Hasil disimpan di `migration-state.json` di folder script: workspace/capacity ID, source-to-target report ID, nama, dataset ID, status dan URL.
- Gunakan **state yang sama** ketika menjalankan ulang pasangan workspace yang sama. Untuk pasangan lain, tambahkan `-StatePath ".\migration-pasangan-lain.json"`.
- Status `CloneRequested` disimpan **sebelum** POST; `Created` setelah mendapatkan ID; `Verified` setelah GET tujuan memastikan ID, nama, dan dataset ID sesuai.
- Move menyimpan `DeleteRequested` sebelum DELETE dan `SourceDeleted` hanya setelah GET sumber mengembalikan HTTP 404. DELETE 200 dengan body kosong ditangani tanpa mencoba membaca JSON.
- Report yang sudah tercatat akan diverifikasi lagi, **tidak di-clone lagi**. Report bernama sama yang tidak tercatat dianggap konflik, bukan otomatis di-skip atau ditimpa.
- GET dapat diulang hingga tiga kali untuk HTTP 429/500/502/503/504; `Retry-After` dalam detik dihormati. POST clone **tidak pernah diulang otomatis**, termasuk timeout, karena report mungkin sudah dibuat server.
- Jika POST gagal/respons hilang, status tetap `CloneRequested` dan proses berhenti dengan error. **Jangan hapus state atau langsung menjalankan ulang dengan state baru.** Cek tujuan dan pastikan hasilnya: jika report terbukti dibuat oleh request tersebut, isi `targetReportId` dan ubah status ke `Created`; jika admin memastikan tidak ada report dibuat, hapus hanya entri report tersebut dari `reports` untuk retry. Jangan mengadopsi report hanya karena namanya sama.
- Jika GET verifikasi gagal, status tetap `Created`; setelah masalah diperbaiki, jalankan ulang dengan state yang sama.
- Jika clone/verifikasi salah satu report gagal, **belum ada report asal dihapus pada pemanggilan itu**. Setelah semua tujuan terverifikasi, semua sumber yang masih ada dicek ulang ID/nama/dataset-nya sebelum penghapusan pertama.
- Jika DELETE gagal/respons hilang, status tetap `DeleteRequested`, dan proses berhenti. Jalankan ulang **`-Mode Move` dengan state yang sama**: tujuan diverifikasi lagi; jika sumber sudah hilang, script memastikan HTTP 404 tanpa mengulang DELETE. Jika sumber masih ada dan identitas/binding cocok, pemanggilan Move baru akan mencoba DELETE lagi. DELETE tidak memiliki retry otomatis dalam pemanggilan yang sama.
- Report dengan `DeleteRequested`/`SourceDeleted` yang sudah tidak ada di daftar sumber tetap bisa dilanjutkan/diverifikasi dalam Move, termasuk jika `-ReportIds` berisi ID asal tersebut. Mode Copy tidak melanjutkan penghapusan tertunda.
- HTTP 403 atau error GET lainnya **bukan bukti penghapusan** dan tidak ditandai `SourceDeleted`. Jika report tujuan hilang atau tidak cocok dengan state, proses berhenti tanpa melanjutkan penghapusan.
- File `.lock` sengaja tetap ada; penguncian aktif hanya selama proses `-Apply` berjalan dan dilepas saat selesai. Jangan jalankan migrasi pasangan yang sama secara bersamaan menggunakan state berbeda/mesin berbeda.
- State ditulis melalui file sementara dan diganti secara atomik. Simpan state sebagai catatan operasional internal, bukan di repositori publik.
- Script berhenti pada kegagalan pertama. Salinan yang sudah dibuat tetap ada dan tercatat; tidak ada rollback otomatis. Pada Move, penghapusan yang sudah selesai tidak dibatalkan dan sumber yang belum dihapus tetap ada.

`Verified` hanya berarti **identitas dan binding dataset lolos pemeriksaan API**, bukan bahwa visual, angka, izin atau RLS telah diuji.

## Checklist sebelum cutover

1. Buka URL report tujuan dari state. Periksa semua halaman, slicer, drillthrough, bookmarks, custom visuals dan angka.
2. Uji sebagai **Viewer/pengguna tujuan**, termasuk RLS dan akses semantic model lintas-workspace; pengujian sebagai Admin saja tidak cukup.
3. Konfigurasi workspace access, sharing, labels dan subscriptions yang diperlukan.
4. Publish/update app dari workspace baru bila digunakan, serta perbarui URL/embed/Teams/dashboard yang menunjuk report lama.
5. Pertahankan report sumber dengan mode Copy sampai penerimaan selesai, lalu gunakan Move jika memang perlu menghapus report asal. **Jangan hapus workspace/model lama selama report baru masih terhubung ke model tersebut.**

## Pengujian lokal tanpa akses tenant

```powershell
pwsh -NoProfile -File .\Tests\Migrate-PowerBIReports.Tests.ps1
```

Tes memakai mock login interaktif, API/token dan folder sementara: tidak membuka prompt login, tidak mengakses tenant, dan tidak membuat report sungguhan.

## Referensi Microsoft Learn

Ditinjau pada 25 November 2026:

- [Clone Report In Group](https://learn.microsoft.com/en-us/rest/api/power-bi/reports/clone-report-in-group): endpoint POST, scope `Content.Create`, `targetWorkspaceId`, dataset asli jika `targetModelId` tidak diberikan, dan perubahan live connection.
- [Delete Report In Group](https://learn.microsoft.com/en-us/rest/api/power-bi/reports/delete-report-in-group): endpoint DELETE report, scope `Report.ReadWrite.All`, dan respons HTTP 200.
- [Get Groups](https://learn.microsoft.com/en-us/rest/api/power-bi/groups/get-groups): daftar workspace, pagination `$top`/`$skip`, `capacityId`, `isOnDedicatedCapacity`, `isReadOnly`.
- [Get Reports In Group](https://learn.microsoft.com/en-us/rest/api/power-bi/reports/get-reports-in-group) dan [Get Report In Group](https://learn.microsoft.com/en-us/rest/api/power-bi/reports/get-report-in-group): inventaris dan verifikasi ID/binding.
- [Copy reports from other workspaces](https://learn.microsoft.com/en-us/power-bi/connect-data/service-datasets-copy-reports): model tetap di lokasi asal, Build permission dan lisensi.
- [Semantic models across workspaces](https://learn.microsoft.com/en-us/power-bi/connect-data/service-datasets-across-workspaces): akses model untuk audience/app dan batasan shared model.
- [Fabric Move Item](https://learn.microsoft.com/en-us/rest/api/fabric/core/items/move-item): hanya memindahkan item ke folder **di workspace yang sama**, bukan antar-workspace.
- [Connect-PowerBIServiceAccount](https://learn.microsoft.com/en-us/powershell/module/microsoftpowerbimgmt.profile/connect-powerbiserviceaccount?view=powerbi-ps): mode User default dengan prompt login interaktif.
- [Get-PowerBIAccessToken](https://learn.microsoft.com/en-us/powershell/module/microsoftpowerbimgmt.profile/get-powerbiaccesstoken?view=powerbi-ps): header autentikasi dari sesi pengguna untuk REST API.
- [Power BI PowerShell overview](https://learn.microsoft.com/en-us/powershell/power-bi/overview?view=powerbi-ps): instalasi modul individual, PowerShell Core, dan kebutuhan versi 1.3.84+ setelah perubahan konfigurasi sign-in.

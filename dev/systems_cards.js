// The Systems Creator's coverage report (plan §10, S3): every server export in types/server.lua,
// beside the cards that stand for it. A card names its export with `api = 'GetPlayer'` (or a list);
// an export that will never be a card is in LEFT_OUT below, with why. Everything else is still open.
//
//   node dev/systems_cards.js          the report, by section
//   node dev/systems_cards.js open     only what is still open
//
// It only reads. Nothing in the game loads this file.
const fs = require('fs');
const path = require('path');
const ROOT = path.join(__dirname, '..');

// Whole sections that are framework plumbing, not something a system does.
const LEFT_OUT_SECTIONS = {
    'Readiness': 'boot plumbing: a system starts after whip_core is ready',
    'Callbacks': 'a signpost, not an export',
    'SecureEvent / SecureCallback': 'for resources that talk to their own clients; a system has no client half yet (S4)',
    'Sentinel (statebag integrity guard)': 'statebag plumbing',
    'Universal Panels': 'a resource\'s own screens (S4 and later)',
    'Themes': 'the look of whip\'s screens',
    'Export binding': 'plumbing',
    'Vehicle Catalog & Images': 'the vehicle pictures and catalogue, for screens',
    'The prop catalogue': 'the furnisher\'s',
    'Damage Modifiers': 'a combat modifier outlives a system: it needs a tag first (core gap)',
};

// Single exports that will not be cards, and why. (A Register* is S3d's: a system's own items,
// stats, shops, jobs and zones.)
const LEFT_OUT = {
    GetPlayerIdentifiers: 'licence and account ids are not a builder\'s to read',
    IsSessionCurrent: 'every card already checks the session (ctx:source)',
    SetPlayerMetadata: 'plan §3: a system keeps its state in its own variables, never character metadata',
    GetPlayerMetadata: 'plan §3, as SetPlayerMetadata',
    SetPlayerFlag: 'plan §3: never Player Flags for a system\'s state (Their Flag reads others\')',
    SetVehicleData: 'plan §3: Vehicle Data is a statebag, wrong for a system\'s state',
    ClearVehicleData: 'plan §3, as SetVehicleData',
    LogActivity: 'the card would flood a timeline; Write to Log is the system\'s own',
    SetPlayerWeatherLayer: 'a layer outlives the system: it needs a tag first (core gap)',
    ClearPlayerWeatherLayer: 'as SetPlayerWeatherLayer',
    ApplyEffect: 'an effect outlives the system and replaces anyone\'s: it needs a tag first (core gap)',
    RemoveEffect: 'as ApplyEffect',
    BankDeposit: 'only moves the ledger; a card needs the ATM\'s cash-to-bank helper first (core gap)',
    BankWithdraw: 'as BankDeposit',
    ZoneRegister: 'its body is a local of zones.lua; S3d Registers makes a system\'s zones',
    ZoneRemove: 'as ZoneRegister',
    StartScenarioRun: 'the Director API\'s; its body is inline',
    EndScenarioRun: 'as StartScenarioRun',
    AddPlayerToScenarioRun: 'as StartScenarioRun',
    SendDirectorEvent: 'as StartScenarioRun',
    CanStartScenarioRun: 'as StartScenarioRun',
    GetScenarioRunOf: 'as StartScenarioRun',
    GetPlayerScenarioRuns: 'as StartScenarioRun (In a Mission? answers yes or no)',
    OnStatChange: 'a resource\'s listener; the systems hear stats through triggers',
    OnVehicleStatChange: 'as OnStatChange',
    SpawnVehicle: 'an owned car out of its garage skips Retrieve; Spawn Temporary Car is a system\'s',
    // Players: an admin's, whip's own, or every player at once
    GetPlayers: 'every player at once: Players Near and Players in Area find them by place',
    IsCharacterDeleted: 'a deleted character is never in a pulse',
    ShowPropSet: 'a held prop is the player\'s game\'s (S4)',
    HidePropSet: 'as ShowPropSet',
    RegisterPermission: 'S3d Registers (admin approved)',
    GetPlayerFlags: 'every flag at once: Their Flag reads one',
    GrantPermission: 'whip permissions are an admin\'s to give',
    RevokePermission: 'as GrantPermission',
    GetPermissionHolders: 'as GrantPermission',
    SavePlayer: 'saving is whip\'s own (one way to save)',
    KickPlayer: 'an admin\'s',
    LogoutPlayer: 'an admin\'s',
    // The Director's runs: the Director API's own
    RemovePlayerFromScenarioRun: 'the Director API\'s own', GetScenarioRunVar: 'the Director API\'s own',
    SetScenarioRunVar: 'the Director API\'s own', SwitchScenario: 'the Director API\'s own',
    GetScenarioRun: 'the Director API\'s own', ListScenarioRuns: 'the Director API\'s own',
    GetScenario: 'the Director API\'s own', ListScenarios: 'the Director API\'s own',
    GetScenarioStats: 'the Director API\'s own', ListDirectorCards: 'the Director\'s own',
    // The bank: someone's accounts are theirs
    GetBankAccount: 'another\'s accounts are private: Has Money? reads this pulse\'s player\'s own',
    GetCharacterBankAccounts: 'as GetBankAccount',
    GetJobBankAccounts: 'as GetBankAccount', GetBankTransactions: 'as GetBankAccount', GetBankAccessList: 'as GetBankAccount',
    CanUseBankAccount: 'as GetBankAccount',
    CreateBankAccount: 'the bank\'s own screens', CloseBankAccount: 'the bank\'s own screens',
    SetBankAccountFrozen: 'an admin\'s', GrantBankAccess: 'the bank\'s own screens (and a job role)', RevokeBankAccess: 'as GrantBankAccess',
    BankSystemDeposit: 'money from nowhere: Pay is the system\'s (owner, log, receipt)',
    BankSystemWithdraw: 'money into nowhere: Charge is the system\'s', BankSystemTransfer: 'as BankSystemDeposit',
    // Jobs
    GetJobs: 'every job at once', EnsureJob: 'S3d Registers', UpdateJob: 'the Job Manager\'s', DeleteJob: 'the Job Manager\'s',
    GetPlayerJobs: 'every job at once: Their Role and Is On Duty? ask about one',
    GetJobEmployees: 'its body is inline in the export (core gap); On-Duty Staff is the card',
    // The inventory: a whole inventory is for screens; moves are Give and Take
    GetInventory: 'a whole inventory is for screens', GetPockets: 'as GetInventory', GetPocketSlots: 'as GetInventory',
    GetPocketMaxWeight: 'as GetInventory: Will It Fit? asks the question',
    FindItem: 'a stack\'s own data is not a builder\'s: Has Item? counts', FindAllItems: 'as FindItem',
    RegisterItem: 'S3d Registers', RegisterItemDefaultMeta: 'S3d Registers', RegisterContextAction: 'a resource\'s',
    RegisterUseHandler: 'S3d Registers', FlushActivityLog: 'plumbing', SanitizeAppearance: 'plumbing',
    RegisterAccessorySlot: 'a resource\'s', GetAccessorySlots: 'a resource\'s', RegisterIgnitionKey: 'a resource\'s',
    GetAllItemDefs: 'the whole catalogue: Item Info reads one',
    // Vehicles: ownership changes are a dealership's
    GetPlayerVehicleKeys: 'every key at once: Has Car Key? asks about one',
    AdoptVehicle: 'ownership changes are a dealership\'s', CreateOwnedVehicle: 'as AdoptVehicle', ClaimVehicle: 'as AdoptVehicle',
    SetVehiclePlate: 'as AdoptVehicle', TransferVehicle: 'as AdoptVehicle', DeleteVehicle: 'as AdoptVehicle',
    OnVehicleDataChange: 'a resource\'s listener',
    SetVehicleDataMany: 'plan §3, as SetVehicleData', ClearAllVehicleData: 'plan §3, as SetVehicleData',
    GetAllVehicleData: 'every key at once: Read Car Data reads one',
    GetGarages: 'every garage at once', GetGarageVehicles: 'a garage\'s whole list is for screens',
    CreateGarage: 'the garage editor\'s', UpdateGarage: 'the garage editor\'s', DeleteGarage: 'the garage editor\'s',
    SetVehicleGarage: 'an admin\'s',
    RegisterVehicleStat: 'S3d Registers', GetAllVehicleStats: 'every stat at once: Car Stat reads one',
    GetStoredVehicleStats: 'as GetAllVehicleStats', SetVehicleStats: 'many at once: Set Car Stat sets one',
    ClearVehicleStat: 'an admin\'s', PurgeVehicleStat: 'an admin\'s',
    // Containers and stores: the inventory's own plumbing
    EnsureContainer: 'S3d Registers', CreateContainer: 'S3d Registers', DeleteContainer: 'S3d Registers', UpdateContainer: 'S3d Registers',
    RegisterStoreKind: 'plumbing', StoreMove: 'the inventory\'s own moves', StoreRead: 'as StoreMove', StoreCount: 'as StoreMove',
    StoreGive: 'as StoreMove: Give Item is a system\'s', StoreTake: 'as StoreMove: Take Item is a system\'s',
    GetItemAt: 'as StoreMove', SetItemMetadata: 'an item\'s own data is its resource\'s', FindItemByUid: 'as StoreMove',
    GetOpenStores: 'as StoreMove', OpenStore: 'a screen (S4)', CloseStore: 'a screen (S4)',
    // Shops: a system's shops are S3d's
    GetShops: 'every shop at once', EnsureShop: 'S3d Registers', CreateShop: 'S3d Registers', DeleteShop: 'S3d Registers',
    UpdateShop: 'S3d Registers', AddCatalogItem: 'S3d Registers', RemoveCatalogItem: 'S3d Registers', GetShopViewers: 'a screen\'s',
    // Time
    SetTimeScale: 'how fast the clock runs is the server\'s own setting',
    SetPlayerTimeOverride: 'outlives the system: it needs a tag first (core gap)', ClearPlayerTimeOverride: 'as SetPlayerTimeOverride',
    HasPlayerTimeOverride: 'as SetPlayerTimeOverride', GetPlayerTimeOverride: 'as SetPlayerTimeOverride',
    GetPlayerWeatherLayers: 'as SetPlayerWeatherLayer',
    // Zones and doors: the editors' own
    GetAllZones: 'every zone at once', GetZoneDef: 'a zone\'s shape is the editor\'s', EnsureZone: 'S3d Registers',
    DeleteZone: 'S3d Registers',
    EnsureDoors: 'the Door Editor\'s', EnsureDoor: 'the Door Editor\'s', CreateDoor: 'the Door Editor\'s', AdoptOrCreateDoor: 'the Door Editor\'s',
    UpdateDoor: 'the Door Editor\'s', DeleteDoor: 'the Door Editor\'s', LinkDoors: 'the Door Editor\'s', UnlinkDoors: 'the Door Editor\'s',
    GetAllDoors: 'every door at once', ReleaseDoor: 'a manager\'s (Give Door Back is a system\'s)', GetDoorHold: 'Lock / Unlock Door holds for itself',
    GetManagedDoors: 'a manager\'s',
    ClosePlayerInventory: 'goes with OpenPlayerInventory', IsCharacterBeingInspected: 'as ClosePlayerInventory',
    RegisterStat: 'S3d Registers', GetAllStats: 'every stat at once: Their Stat reads one', GetEffects: 'every effect at once: Has Effect? asks about one',
    // Properties: sales and packs are another session's, and the furnisher's
    GetProperties: 'every property at once', GetCharacterProperties: 'whose homes are whose is private',
    SetPropertyOwner: 'property sales (the housing system\'s)',
    RegisterPropertyPack: 'the housing system\'s', GetPropertyPacks: 'the housing system\'s',
    IsPlaceableProp: 'the furnisher\'s',
    ListPoints: 'a system\'s points are its Point Used cards\'',
    UpdatePoint: 'a system\'s points are its Point Used cards\'', RemovePoint: 'as UpdatePoint',
    SetVehicleAppearance: 'a car\'s look is a customs screen\'s (S4)', RestoreVehicleAppearance: 'as SetVehicleAppearance',
    GetContainer: 'a container\'s contents are its own: S3d Registers makes a system\'s',
    BankTransfer: 'account ids are private: Pay and Charge move a system\'s money',
    DeleteGroundItem: 'it destroys whatever someone dropped',
    ListNpcs: 'every NPC at once: About the NPC reads one',
};

function readExports() {
    const lines = fs.readFileSync(path.join(ROOT, 'types', 'server.lua'), 'utf8').split(/\r?\n/);
    const out = [];
    let section = '(top)';
    for (let i = 0; i < lines.length; i++) {
        if (/^-- =+$/.test(lines[i]) && /^-- =+$/.test(lines[i + 2] || '')) {
            const m = /^-- (.+)$/.exec(lines[i + 1] || '');
            if (m) section = m[1].trim();
        }
        const f = /^function whip_core:([A-Za-z_][A-Za-z0-9_]*)\(/.exec(lines[i]);
        if (f) out.push({ name: f[1], section });
    }
    return out;
}

function readCards() {
    const dirs = [path.join(ROOT, 'server', 'systems'), path.join(ROOT, 'shared', 'systems')];
    const byApi = new Map();
    for (const dir of dirs) {
        for (const file of fs.readdirSync(dir)) {
            if (!/^cards.*\.lua$/.test(file)) continue;
            for (const line of fs.readFileSync(path.join(dir, file), 'utf8').split(/\r?\n/)) {
                // `api = 'X'`, `api = { 'X', 'Y' }`, or a helper's `api = grant and 'X' or 'Y'`: every
                // quoted name after it that starts with a capital (card types are lower case).
                const at = line.indexOf('api = ');
                if (at < 0 || /^\s*--/.test(line)) continue;
                const rest = line.slice(at + 6).split(/,\s*(?:fn|desc|title|kind|category)\b/)[0];
                const t = /type = '([a-z]\w*\.[A-Za-z_]\w*)'/.exec(line);
                for (const m of rest.matchAll(/'([A-Z]\w*)'/g)) {
                    if (!byApi.has(m[1])) byApi.set(m[1], []);
                    byApi.get(m[1]).push(t ? t[1] : '(a helper\'s cards)');
                }
            }
        }
    }
    return byApi;
}

const exportsList = readExports();
const byApi = readCards();
const known = new Set(exportsList.map((e) => e.name));
const onlyOpen = process.argv[2] === 'open';
let covered = 0, left = 0, open = 0;
const sections = new Map();
for (const e of exportsList) {
    if (!sections.has(e.section)) sections.set(e.section, []);
    sections.get(e.section).push(e);
}
const lines = [];
for (const [section, list] of sections) {
    const rows = [];
    for (const e of list) {
        let status, note;
        if (byApi.has(e.name)) { status = 'card'; note = byApi.get(e.name).join(', '); covered++; }
        else if (LEFT_OUT_SECTIONS[section]) { status = 'left out'; note = LEFT_OUT_SECTIONS[section]; left++; }
        else if (LEFT_OUT[e.name]) { status = 'left out'; note = LEFT_OUT[e.name]; left++; }
        else { status = 'OPEN'; note = ''; open++; }
        if (!onlyOpen || status === 'OPEN') rows.push(`  ${status.padEnd(8)} ${e.name}${note ? `  (${note})` : ''}`);
    }
    if (rows.length) lines.push(`${section}`, ...rows);
}
// A card naming an export that is not in types/server.lua is a typo (or the export went).
const strays = [...byApi.keys()].filter((n) => !known.has(n));
console.log(lines.join('\n'));
console.log(`\n${exportsList.length} server exports: ${covered} with a card, ${left} left out on purpose, ${open} open.`);
if (strays.length) {
    console.log(`Cards name exports types/server.lua does not have: ${strays.join(', ')}`);
    process.exitCode = 1;
}

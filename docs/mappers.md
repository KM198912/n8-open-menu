# Mapper list

Mappers the original N8 firmware lists on its "Supported Mappers"
screen (151 mappers), and where n8-open stands on each. Our RBF number
is 100 + mapper, in `/EDFC/MAPS/`. Names are filled in where they are
well known; `-` = still to look up (NESdev wiki).

n8-open: 20 of 151 have a core (see the status column).

| Mapper | Name | Status | RBF | Tested with |
|---:|---|---|---|---|
| 0 | NROM | done | `100.RBF` | Super Mario Bros., hello.nes |
| 1 | MMC1 (SxROM) | done | `101.RBF` | Zelda (Europe), Zelda II |
| 2 | UxROM | done | `102.RBF` | Castlevania (USA, Europe) |
| 3 | CNROM | done | `103.RBF` | Solomon's Key |
| 4 | MMC3 (TxROM) | done | `104.RBF` | Super Mario Bros. 3, Darkwing Duck |
| 5 | MMC5 (ExROM) | partial: saves 8 KB only | `105.RBF` | Castlevania III, Just Breed, Nobunaga's Ambition II, Uchuu Keibitai SDF, Hero of Aethel |
| 7 | AxROM | done | `107.RBF` | Battletoads |
| 9 | MMC2 (PxROM) | done | `109.RBF` | Mike Tyson's Punch-Out!! |
| 10 | MMC4 (FxROM) | done | `110.RBF` | Fire Emblem Gaiden (incl. battery save) |
| 11 | Color Dreams | done | `111.RBF` | Crystal Mines |
| 12 | - | open | - | - |
| 13 | CPROM | open | - | - |
| 15 | - | open | - | - |
| 16 | Bandai FCG | open | - | - |
| 18 | Jaleco SS88006 | open | - | - |
| 19 | Namco 163 | open | - | - |
| 21 | VRC4a / VRC4c | done | `121.RBF` | Wai Wai World 2 |
| 22 | VRC2a | done | `122.RBF` | TwinBee 3 |
| 23 | VRC2b / VRC4e/f | done | `123.RBF` | Tiny Toon Adventures (J) (iNES 1.0 header: the second address pair) |
| 24 | VRC6a | done (incl. audio) | `124.RBF` | Akumajou Densetsu |
| 25 | VRC4b/d / VRC2c | done | `125.RBF` | Gradius II (IRQ, PAL correction) |
| 26 | VRC6b | done | `126.RBF` | Mouryou Senki Madara |
| 28 | Action 53 | open | - | - |
| 30 | UNROM 512 | open | - | - |
| 31 | - | open | - | - |
| 32 | Irem G-101 | open | - | - |
| 33 | Taito TC0190 | open | - | - |
| 34 | BNROM / NINA-001 | done | `134.RBF` | Deadly Towers (BNROM), Impossible Mission II (NINA-001) |
| 36 | - | open | - | - |
| 37 | - | open | - | - |
| 38 | - | open | - | - |
| 40 | - | open | - | - |
| 41 | - | open | - | - |
| 42 | - | open | - | - |
| 45 | - | open | - | - |
| 47 | - | open | - | - |
| 48 | Taito TC0690 | open | - | - |
| 49 | - | open | - | - |
| 51 | - | open | - | - |
| 52 | - | open | - | - |
| 57 | - | open | - | - |
| 58 | - | open | - | - |
| 61 | - | open | - | - |
| 64 | Tengen RAMBO-1 | open | - | - |
| 65 | Irem H3001 | open | - | - |
| 66 | GxROM | done | `166.RBF` | Super Mario Bros. / Duck Hunt |
| 67 | Sunsoft-3 | open | - | - |
| 68 | Sunsoft-4 | open | - | - |
| 69 | Sunsoft FME-7 | done (no 5B audio) | `169.RBF` | Batman: Return of the Joker |
| 70 | - | open | - | - |
| 71 | Camerica / Codemasters | done | `171.RBF` | Micro Machines, Fire Hawk |
| 72 | - | open | - | - |
| 73 | VRC3 | open | - | - |
| 74 | - | open | - | - |
| 75 | VRC1 | open | - | - |
| 76 | - | open | - | - |
| 77 | - | open | - | - |
| 78 | - | open | - | - |
| 79 | AVE NINA-03/06 | open | - | - |
| 80 | Taito X1-005 | open | - | - |
| 82 | Taito X1-017 | open | - | - |
| 85 | VRC7 | open | - | - |
| 86 | Jaleco JF-13 | open | - | - |
| 87 | - | open | - | - |
| 88 | - | open | - | - |
| 89 | - | open | - | - |
| 90 | - | open | - | - |
| 91 | - | open | - | - |
| 92 | - | open | - | - |
| 93 | - | open | - | - |
| 94 | - | open | - | - |
| 95 | - | open | - | - |
| 96 | - | open | - | - |
| 97 | - | open | - | - |
| 99 | Vs. System | open | - | - |
| 101 | - | open | - | - |
| 105 | NES-EVENT (NWC 1990) | open | - | - |
| 107 | - | open | - | - |
| 108 | - | open | - | - |
| 112 | - | open | - | - |
| 113 | - | open | - | - |
| 115 | - | open | - | - |
| 118 | TxSROM (MMC3) | open | - | - |
| 119 | TQROM (MMC3) | open | - | - |
| 133 | - | open | - | - |
| 137 | - | open | - | - |
| 138 | - | open | - | - |
| 139 | - | open | - | - |
| 140 | - | open | - | - |
| 141 | - | open | - | - |
| 142 | - | open | - | - |
| 143 | - | open | - | - |
| 145 | - | open | - | - |
| 146 | - | open | - | - |
| 147 | - | open | - | - |
| 148 | - | open | - | - |
| 149 | - | open | - | - |
| 150 | - | open | - | - |
| 151 | - | open | - | - |
| 152 | - | open | - | - |
| 154 | - | open | - | - |
| 156 | - | open | - | - |
| 158 | - | open | - | - |
| 164 | - | open | - | - |
| 165 | - | open | - | - |
| 171 | - | open | - | - |
| 175 | - | open | - | - |
| 176 | - | open | - | - |
| 177 | - | open | - | - |
| 178 | - | open | - | - |
| 180 | - | open | - | - |
| 182 | - | open | - | - |
| 184 | Sunsoft-1 | open | - | - |
| 185 | - | open | - | - |
| 188 | - | open | - | - |
| 189 | - | open | - | - |
| 191 | - | open | - | - |
| 193 | - | open | - | - |
| 196 | - | open | - | - |
| 197 | - | open | - | - |
| 200 | - | open | - | - |
| 201 | - | open | - | - |
| 202 | - | open | - | - |
| 203 | - | open | - | - |
| 205 | - | open | - | - |
| 206 | Namco 108 (DxROM) | open | - | - |
| 207 | - | open | - | - |
| 211 | - | open | - | - |
| 212 | - | open | - | - |
| 213 | - | open | - | - |
| 214 | - | open | - | - |
| 216 | - | open | - | - |
| 219 | - | open | - | - |
| 220 | - | open | - | - |
| 222 | - | open | - | - |
| 227 | - | open | - | - |
| 228 | Action 52 | open | - | - |
| 229 | - | open | - | - |
| 231 | - | open | - | - |
| 232 | Camerica Quattro | open | - | - |
| 234 | - | open | - | - |
| 240 | - | open | - | - |
| 241 | - | open | - | - |
| 242 | - | open | - | - |
| 243 | - | open | - | - |
| 244 | - | open | - | - |
| 245 | - | open | - | - |
| 246 | - | open | - | - |
| 249 | - | open | - | - |
| 250 | - | open | - | - |
| 252 | - | open | - | - |

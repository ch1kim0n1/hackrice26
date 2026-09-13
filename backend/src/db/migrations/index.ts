import { migration as initial } from "./001_initial";
import { migration as integrity } from "./002_integrity";
import { migration as cauldron } from "./003_cauldron";
import { migration as characterSystem } from "./004_character_system";
import { migration as mines } from "./005_mines";
import { migration as plinko } from "./006_plinko";
import { migration as coinsAndLocks } from "./007_coins_and_locks";
import { migration as characterLedger } from "./008_character_ledger";
import { migration as portalWheel } from "./009_portal_wheel";
import { migration as humanGate } from "./010_human_gate";
import { migration as humanGatePersona } from "./011_human_gate_persona";
import { migration as mirrorOutbox } from "./012_mirror_outbox";
import { migration as caseCoinReason } from "./013_case_coin_reason";
import { migration as collectionDrops } from "./014_collection_drops";
import { migration as cookbookEconomy } from "./015_cookbook_economy";
import { migration as scanMintAndMeals } from "./016_scan_mint_and_meals";
import { migration as progression } from "./017_progression";
import { migration as battleMatches } from "./018_battle_matches";
import { migration as healMissingTables } from "./019_heal_missing_tables";

export const migrations = [
  initial,
  integrity,
  cauldron,
  characterSystem,
  mines,
  plinko,
  coinsAndLocks,
  characterLedger,
  portalWheel,
  humanGate,
  humanGatePersona,
  mirrorOutbox,
  caseCoinReason,
  collectionDrops,
  cookbookEconomy,
  scanMintAndMeals,
  progression,
  battleMatches,
  healMissingTables
];

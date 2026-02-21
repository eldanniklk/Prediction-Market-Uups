# PredictionMarket UUPS (Foundry)

Prediction market diario UP/DOWN para BTC, ETH y DOT, con:
- colateral nativo en Paseo (`msg.value`, token PAS)
- orderbook EIP-712 (sin AMM)
- ejecución vía matcher
- contrato upgradeable UUPS

Este repo está preparado para la siguiente fase: integrar una web (UI + firma de órdenes) y un bot/oracle runner que publique precios en tiempo real para resolver epochs.

## 1. Estado actual

Ya implementado y probado:
- contrato principal UUPS: `src/PredictionMarketUpgradeable.sol`
- contrato V2 para upgrade test: `src/PredictionMarketUpgradeableV2.sol`
- scripts Foundry de deploy/upgrade
- tests E2E en Solidity (Foundry)

Modelo funcional:
- mercados diarios por asset (`EPOCH_DURATION = 1 day`)
- outcomes por epoch: `UP` / `DOWN`
- precio de share en `priceBps` (válido `1..9999`)
- payout final: share ganadora = `1:1`, perdedora = `0`
- usuarios no mintean shares
- `mint` y `merge` solo `owner` o `treasury`, sobre balance de `treasury`

## 2. Arquitectura (hoy)

Componentes on-chain:
- `PredictionMarketUpgradeable` (proxy logic)
  - depósitos/retiros nativos
  - epochs diarios y resolución
  - matching de órdenes EIP-712
  - claim 1:1
  - administración (`owner`, `matcher`, `treasury`, pausa)
- `ERC1967Proxy` (UUPS)
- `PredictionMarketUpgradeableV2` (upgrade target de ejemplo)

```text
Users/Bot/Matcher/UI
        |
        v
+------------------+   delegatecall   +------------------------------+
|   ERC1967Proxy   | ---------------> | PredictionMarketUpgradeable   |
| (state lives)    |                  | (UUPS implementation)         |
+------------------+                  +------------------------------+
        |
        v upgradeTo(newImpl) [onlyOwner]
+------------------------------+
| PredictionMarket...V2/V3...  |
+------------------------------+
```

Actores:
- `owner`: administra matcher, treasury, prices y upgrades
- `treasury`: crea inventario inicial de shares (`mint`/`merge`)
- `matcher`: ejecuta `matchOrdersPolymarketStyle`
- `user`: deposita PAS, firma órdenes, hace claim y retira

## 3. Flujo operativo

1. Owner publica precios (`pushPrice`) y abre epochs con `bootstrapDailyEpochs`.
2. Treasury deposita PAS y crea inventario (`mint`) para ofrecer liquidez.
3. Usuario deposita PAS (`depositCollateral`).
4. Usuario/treasury firman órdenes EIP-712 off-chain.
5. Matcher ejecuta `matchOrdersPolymarketStyle`.
6. Al cierre, owner resuelve epoch (`resolveEpoch` / `rollDaily`).
7. Usuario cobra con `claim` y puede retirar con `withdrawCollateral`.

## 4. Estructura del repo

- `src/PredictionMarketUpgradeable.sol`
- `src/PredictionMarketUpgradeableV2.sol`
- `test/PredictionMarket.t.sol`
- `script/DeployProxy.s.sol` (recomendado para Paseo)
- `script/UpgradeToV2.s.sol`

Scripts legacy/alternativos en `script/` pueden seguir existiendo, pero el flujo recomendado es `DeployProxy` + `UpgradeToV2`.

## 5. Requisitos

- Foundry (`forge`, `cast`)
- RPC Paseo: `https://eth-rpc-testnet.polkadot.io/`
- cuenta con saldo PAS para deploy/upgrade

## 6. Variables de entorno

Ejemplo mínimo (`.env`):

```bash
RPC_URL=https://eth-rpc-testnet.polkadot.io/
CHAIN_ID=420420417
PRIVATE_KEY=<hex_sin_0x>
OWNER=0x...
MATCHER=0x...
PROXY=0x...   # para upgrade
```

Puedes partir de `.env.example`:

```bash
cp .env.example .env
```

Notas:
- `OWNER` y `MATCHER` deben ser explícitos.
- `OWNER` queda como owner inicial y treasury inicial.
- no commitear `.env` ni claves privadas al repo.

## 7. Build y tests

```bash
forge clean
forge build
forge test -vv
```

## 8. Deploy en Paseo (UUPS proxy)

Comando recomendado (Paseo):

```bash
forge script script/DeployProxy.s.sol:DeployProxy -vvvv \
  --rpc-url $RPC_URL \
  --broadcast \
  --legacy \
  --gas-estimate-multiplier 1000
```

La bandera `--gas-estimate-multiplier 1000` evita fallos de estimación observados en este RPC durante CREATE/CREATE2 de contratos proxy.

Verificación posterior:

```bash
cast code <PROXY> --rpc-url $RPC_URL
cast call <PROXY> "owner()(address)" --rpc-url $RPC_URL
cast call <PROXY> "treasury()(address)" --rpc-url $RPC_URL
cast call <PROXY> "matcherAddress()(address)" --rpc-url $RPC_URL
```

Debe cumplirse:
- `cast code` != `0x`
- `owner == OWNER`
- `treasury == OWNER` (inicialmente)
- `matcherAddress == MATCHER`

## 9. Upgrade UUPS a V2

```bash
forge script script/UpgradeToV2.s.sol:UpgradeToV2 -vvvv \
  --rpc-url $RPC_URL \
  --broadcast \
  --legacy \
  --gas-estimate-multiplier 1000
```

Verificar:

```bash
cast call <PROXY> "version()(string)" --rpc-url $RPC_URL
```

Esperado:
- `"v2"`

## 10. Quickstart: Market live (manual)

Flujo mínimo para levantar un mercado manualmente (asset BTC = `0`):

```bash
# 1) pushPrice(uint8,uint80,int192,uint256)
TS=$(cast block latest --rpc-url $RPC_URL --field timestamp)
cast send $PROXY "pushPrice(uint8,uint80,int192,uint256)" 0 1 5000000 $TS --rpc-url $RPC_URL --private-key $PRIVATE_KEY

# 2) bootstrapDailyEpochs()
cast send $PROXY "bootstrapDailyEpochs()" --rpc-url $RPC_URL --private-key $PRIVATE_KEY

# 3) depositCollateral() con una cuenta de usuario
cast send $PROXY "depositCollateral()" --value 0.01ether --rpc-url $RPC_URL --private-key $USER_PRIVATE_KEY

# 4) leer estado básico
USER=$(cast wallet address --private-key $USER_PRIVATE_KEY)
cast call $PROXY "getFreeCollateral(address)(uint256)" $USER --rpc-url $RPC_URL
cast call $PROXY "getCurrentEpoch(uint8)(uint256,(uint64,uint64,uint80,uint80,int192,int192,bool,uint8))" 0 --rpc-url $RPC_URL
```

## 11. Roadmap: web + bot de precios

### Fase Web (frontend)

Objetivo:
- UI para depositar/retirar
- firma de órdenes EIP-712 (BUY/SELL)
- visualización de orderbook y posición del usuario
- claim al resolver epoch

Checklist técnico:
- ABIs del proxy + dirección por red
- signer wallet (EIP-712 typed data)
- backend ligero o matcher service para discovery de órdenes
- manejo de nonces/cancelaciones (`cancelNonce`, `cancelAllUpTo`)

### Fase Bot (oracle / automation)

Objetivo:
- publicar precios con `pushPrice`
- ejecutar `bootstrapDailyEpochs` al iniciar el día
- resolver/rodar epochs con `resolveEpoch` / `rollDaily`

Recomendación de diseño:
- proceso daemon con scheduler UTC
- source de precios redundante (2+ proveedores)
- política de tolerancia y validación previa
- alertas (Discord/Telegram/Slack) para fallos
- runbook de emergencia (pausa, retry, rollback operativo)

## 12. Seguridad y operación

- mantener `owner` y `treasury` en multisig al pasar a producción
- restringir y monitorear `matcherAddress`
- usar claves separadas para deploy/admin/oracle bot
- registrar y auditar upgrades UUPS
- no exponer `PRIVATE_KEY` en logs ni CI

## 13. Problemas conocidos en Paseo (importante)

- El RPC puede subestimar gas en despliegues de proxy.
- Síntoma: tx de CREATE con `status=0`, `gasUsed` muy bajo, proxy sin código.
- Mitigación efectiva en este repo:
  - `--legacy`
  - `--gas-estimate-multiplier 1000`

## 14. Comandos rápidos

Deploy + verificación:

```bash
forge script script/DeployProxy.s.sol:DeployProxy -vvvv --rpc-url $RPC_URL --broadcast --legacy --gas-estimate-multiplier 1000
cast call $PROXY "owner()(address)" --rpc-url $RPC_URL
cast call $PROXY "treasury()(address)" --rpc-url $RPC_URL
cast call $PROXY "matcherAddress()(address)" --rpc-url $RPC_URL
```

Upgrade + check:

```bash
forge script script/UpgradeToV2.s.sol:UpgradeToV2 -vvvv --rpc-url $RPC_URL --broadcast --legacy --gas-estimate-multiplier 1000
cast call $PROXY "version()(string)" --rpc-url $RPC_URL
```

#!/usr/bin/env sh
# Exporta los ABIs compilados a frontend/src/abi.
#
# La v1 tenia los ABIs pegados a mano dentro de los componentes de React
# (~1400 de las 1700 lineas de src/), asi que cualquier cambio en un contrato
# los dejaba desincronizados en silencio. Aqui se regeneran desde los
# artifacts de forge, que son la unica fuente de verdad.
#
#   ./export-abis.sh
set -eu

cd "$(dirname "$0")"
OUT="../frontend/src/abi"
mkdir -p "$OUT"

forge build --silent

for name in CollateralVotingVault GovStablecoin DelegationAccount MockGovernanceToken; do
  printf '// Generado por contracts/export-abis.sh. No editar a mano.\n' > "$OUT/$name.json.js"
  printf 'export const %sAbi = ' "$(printf '%s' "$name" | cut -c1 | tr '[:upper:]' '[:lower:]')$(printf '%s' "$name" | cut -c2-)" >> "$OUT/$name.json.js"
  forge inspect "$name" abi --json >> "$OUT/$name.json.js"
  printf ';\n' >> "$OUT/$name.json.js"
  mv "$OUT/$name.json.js" "$OUT/$name.js"
  echo "  $OUT/$name.js"
done

echo "ABIs exportados."

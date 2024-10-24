
require("./testnet-common.js")();

async function main() {
    await deployTestnetContracts("SENT Token (devnet v3)", "DEVSENT3", /*tokenAddress*/ "");
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});

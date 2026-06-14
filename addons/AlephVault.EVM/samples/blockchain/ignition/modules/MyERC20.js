const { buildModule } = require("@nomicfoundation/hardhat-ignition/modules");

module.exports = buildModule("MyERC20", (m) => {
  const contract = m.contract(
    "MyERC20", []
  );

  m.call(contract, "mint", [
      "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266",
      "10000000000000000000000"
  ]);

  return { contract };
});

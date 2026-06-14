const { buildModule } = require("@nomicfoundation/hardhat-ignition/modules");

module.exports = buildModule("MyERC20", (m) => {
  // You can pass parameters (e.g. "foo") to this module and attend
  // or capture them by using line like this one:
  //
  // (parameter keys must be valid alphanumeric strings, and parameter
  // values, both expected and default, must be json-serializable ones,
  // which can be numbers, boolean values, strings or null)
  //
  // const foo = m.getParameter("foo", "someValue");

  // This is a simple module which only deploys a contract. The result
  // of m.contract is a special value (not an actual contract nor its
  // address) that makes part of the ignition declarative paradigm: a
  // "future". Read more about ignition and futures in the official
  // documentation @ Hardhat's website.

  // The [] receives as many argument as your contract needs. Those
  // will be passed directly to the constructor.

  const contract = m.contract(
    "MyERC20", []
  );

  // In this case, the result is a single object having a contract: key
  // which contains the future. When Ignition deployment is invoked and
  // retrieved via code, the result will be a single object having a
  // contract: key which contains a Contract instance (from `ethers` or
  // `viem` or whatever biding you're using for Ignition).

  // Feel free to edit this file as needed, but it's a good idea to keep
  // the object with the contract: key (you can freely add more keys) or
  // other tools based on this one might not work for your script.

  return { contract };
});

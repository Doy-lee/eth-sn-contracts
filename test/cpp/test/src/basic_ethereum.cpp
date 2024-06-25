#include <iostream>

#include "ethyl/provider.hpp"
#include "ethyl/signer.hpp"
#include "service_node_rewards/config.hpp"
#include <oxenc/hex.h>

#include <catch2/catch_test_macros.hpp>
#include <catch2/catch_all.hpp>
#include <cybozu/endian.hpp>

extern "C" {
#include "crypto/keccak.h"
}

#if 0
TEST_CASE( "Get balance from local network", "[ethereum]" ) {
    const auto& config = ethbls::get_config(ethbls::network_type::LOCAL);
    ethyl::Provider client;
    client.addClient("Local Client", std::string(config.RPC_URL));

    // Get the balance of the first hardhat address and make sure it has a balance
    auto balance = client.getBalance("0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266");
    REQUIRE( balance != "0");
}

TEST_CASE( "Get latest contract address", "[ethereum]" ) {
    const auto& config = ethbls::get_config(ethbls::network_type::LOCAL);
    ethyl::Provider client;
    client.addClient("Local Client", std::string(config.RPC_URL));

    // Get the deployed contract, make sure it exists
    auto contract_address = client.getContractDeployedInLatestBlock();
    REQUIRE(contract_address != "");
}
#endif

static void expand_message_xmd_keccak256_single(uint8_t out[], size_t outSize, const void *msg, size_t msgSize, const void *dst, size_t dstSize)
{
    const size_t mdSize = 32;
    assert((outSize % mdSize) == 0 && 0 < outSize && outSize <= 256);
    assert(dstSize <= 255);
    const size_t r_in_bytes = 136;
    const size_t n = outSize / mdSize;
    static const uint8_t Z_pad[r_in_bytes] = {};
    /*
            Z_apd | msg | BE(outSize, 2) | BE(0, 1) | DST | BE(dstSize, 1)
    */
    uint8_t lenBuf[2];
    uint8_t iBuf = 0;
    uint8_t dstSizeBuf = uint8_t(dstSize);
    cybozu::Set16bitAsBE(lenBuf, uint16_t(outSize));

    KECCAK_CTX keccak_ctx;
    keccak_init(&keccak_ctx);

    keccak_update(&keccak_ctx, Z_pad, r_in_bytes);
    keccak_update(&keccak_ctx, reinterpret_cast<const uint8_t *>(msg), msgSize);
    keccak_update(&keccak_ctx, lenBuf, sizeof(lenBuf));
    keccak_update(&keccak_ctx, &iBuf, sizeof(iBuf));
    keccak_update(&keccak_ctx, reinterpret_cast<const uint8_t *>(dst), dstSize);
    keccak_update(&keccak_ctx, &dstSizeBuf, sizeof(dstSizeBuf));

    uint8_t md[mdSize];
    keccak_finish(&keccak_ctx, md);

    keccak_ctx = {};
    keccak_init(&keccak_ctx);

    keccak_update(&keccak_ctx, md, mdSize);
    iBuf = 1;
    keccak_update(&keccak_ctx, &iBuf, sizeof(iBuf));
    keccak_update(&keccak_ctx, reinterpret_cast<const uint8_t *>(dst), dstSize);
    keccak_update(&keccak_ctx, &dstSizeBuf, sizeof(dstSizeBuf));

    keccak_finish(&keccak_ctx, out);

    uint8_t mdXor[mdSize];
    for (size_t i = 1; i < n; i++) {
        keccak_ctx = {};
        keccak_init(&keccak_ctx);
        for (size_t j = 0; j < mdSize; j++) {
            mdXor[j] = md[j] ^ out[mdSize * (i - 1) + j];
        }
        keccak_update(&keccak_ctx, mdXor, mdSize);
        iBuf = uint8_t(i + 1);
        keccak_update(&keccak_ctx, &iBuf, sizeof(iBuf));
        keccak_update(&keccak_ctx, reinterpret_cast<const uint8_t *>(dst), dstSize);
        keccak_update(&keccak_ctx, &dstSizeBuf, sizeof(dstSizeBuf));

        keccak_finish(&keccak_ctx, out + mdSize * i);
    }
}


TEST_CASE("expand message using keccak", "[hashToField]") {
    std::string_view msg_raw = "hello";
    std::string msg          = oxenc::to_hex(msg_raw.begin(), msg_raw.end());
    uint8_t md[96] = {};
    expand_message_xmd_keccak256_single(md, sizeof(md), msg.data(), msg.size(), nullptr, 0);

    std::string chunk32[] ={
        oxenc::to_hex(std::begin(md) + 0,  std::begin(md) + 32),
        oxenc::to_hex(std::begin(md) + 32, std::begin(md) + 64),
        oxenc::to_hex(std::begin(md) + 64, std::begin(md) + 96),
    };

    // Should match the results from the smart contracts
    //
    //     describe("expand_message_xmd_keccak256", function () {
    //       it.only("should not revert", async function () {
    //         const message = "asdf";
    //         const hexMsg = ethers.hexlify(ethers.toUtf8Bytes(message));
    //         console.log(hexMsg);
    //         await expect(hashToField.expand_message_xmd_keccak256(hexMsg, hexMsg)).to.not.be.reverted;
    //         console.log(await hashToField.expand_message_xmd_keccak256(hexMsg, hexMsg));
    //       });
    //     });
    CHECK(chunk32[0] == "b994e6536d2e70d761fb288eb2bed4576dfc0638478d189d78cb4b0b06b6afa2");
    CHECK(chunk32[1] == "b994e6536d2e70d761fb288eb2bed4576dfc0638478d189d78cb4b0b06b6afa2");
    CHECK(chunk32[2] == "8e5cd255bb8bb47f84501ee1c990759ab2094f02e732e6ff0942685d4f4139aa");
}

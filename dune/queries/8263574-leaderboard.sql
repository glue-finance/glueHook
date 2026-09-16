WITH glue_swaps AS (
    SELECT 'ethereum' AS blockchain, tx_hash, evt_index FROM uniswap_v4_ethereum.base_trades
    WHERE hooks IN (0xb216070c3509047ea597e2e626a29cea427a60c8, 0x0f41715dc432692b66a5adf8dcfef6ac407b20c8, 0xbb021554c5294328b04fa313669715bd201ba040, 0x03d482cb3ff339c2d29736818d0f72c66dd6a040) AND block_number >= 25703029 AND block_date >= DATE '2026-06-01'
    UNION ALL
    SELECT 'base' AS blockchain, tx_hash, evt_index FROM uniswap_v4_base.base_trades
    WHERE hooks IN (0xb216070c3509047ea597e2e626a29cea427a60c8, 0x0f41715dc432692b66a5adf8dcfef6ac407b20c8, 0xbb021554c5294328b04fa313669715bd201ba040, 0x03d482cb3ff339c2d29736818d0f72c66dd6a040) AND block_number >= 49657824 AND block_date >= DATE '2026-06-01'
    UNION ALL
    SELECT 'arbitrum' AS blockchain, tx_hash, evt_index FROM uniswap_v4_arbitrum.base_trades
    WHERE hooks IN (0xb216070c3509047ea597e2e626a29cea427a60c8, 0x0f41715dc432692b66a5adf8dcfef6ac407b20c8, 0xbb021554c5294328b04fa313669715bd201ba040, 0x03d482cb3ff339c2d29736818d0f72c66dd6a040) AND block_number >= 492046075 AND block_date >= DATE '2026-06-01'
    UNION ALL
    SELECT 'optimism' AS blockchain, tx_hash, evt_index FROM uniswap_v4_optimism.base_trades
    WHERE hooks IN (0xb216070c3509047ea597e2e626a29cea427a60c8, 0x0f41715dc432692b66a5adf8dcfef6ac407b20c8, 0xbb021554c5294328b04fa313669715bd201ba040, 0x03d482cb3ff339c2d29736818d0f72c66dd6a040) AND block_number >= 155253116 AND block_date >= DATE '2026-06-01'
    UNION ALL
    SELECT 'bnb' AS blockchain, tx_hash, evt_index FROM uniswap_v4_bnb.base_trades
    WHERE hooks IN (0xb216070c3509047ea597e2e626a29cea427a60c8, 0x0f41715dc432692b66a5adf8dcfef6ac407b20c8, 0xbb021554c5294328b04fa313669715bd201ba040, 0x03d482cb3ff339c2d29736818d0f72c66dd6a040) AND block_number >= 114546905 AND block_date >= DATE '2026-06-01'
    UNION ALL
    SELECT 'polygon' AS blockchain, tx_hash, evt_index FROM uniswap_v4_polygon.base_trades
    WHERE hooks IN (0xb216070c3509047ea597e2e626a29cea427a60c8, 0x0f41715dc432692b66a5adf8dcfef6ac407b20c8, 0xbb021554c5294328b04fa313669715bd201ba040, 0x03d482cb3ff339c2d29736818d0f72c66dd6a040) AND block_number >= 91600016 AND block_date >= DATE '2026-06-01'
    UNION ALL
    SELECT 'avalanche_c' AS blockchain, tx_hash, evt_index FROM uniswap_v4_avalanche_c.base_trades
    WHERE hooks IN (0xb216070c3509047ea597e2e626a29cea427a60c8, 0x0f41715dc432692b66a5adf8dcfef6ac407b20c8, 0xbb021554c5294328b04fa313669715bd201ba040, 0x03d482cb3ff339c2d29736818d0f72c66dd6a040) AND block_number >= 92242906 AND block_date >= DATE '2026-06-01'
    UNION ALL
    SELECT 'blast' AS blockchain, tx_hash, evt_index FROM uniswap_v4_blast.base_trades
    WHERE hooks IN (0xb216070c3509047ea597e2e626a29cea427a60c8, 0x0f41715dc432692b66a5adf8dcfef6ac407b20c8, 0xbb021554c5294328b04fa313669715bd201ba040, 0x03d482cb3ff339c2d29736818d0f72c66dd6a040) AND block_date >= DATE '2026-06-01'
    UNION ALL
    SELECT 'celo' AS blockchain, tx_hash, evt_index FROM uniswap_v4_celo.base_trades
    WHERE hooks IN (0xb216070c3509047ea597e2e626a29cea427a60c8, 0x0f41715dc432692b66a5adf8dcfef6ac407b20c8, 0xbb021554c5294328b04fa313669715bd201ba040, 0x03d482cb3ff339c2d29736818d0f72c66dd6a040) AND block_date >= DATE '2026-06-01'
    UNION ALL
    SELECT 'zora' AS blockchain, tx_hash, evt_index FROM uniswap_v4_zora.base_trades
    WHERE hooks IN (0xb216070c3509047ea597e2e626a29cea427a60c8, 0x0f41715dc432692b66a5adf8dcfef6ac407b20c8, 0xbb021554c5294328b04fa313669715bd201ba040, 0x03d482cb3ff339c2d29736818d0f72c66dd6a040) AND block_date >= DATE '2026-06-01'
    UNION ALL
    SELECT 'worldchain' AS blockchain, tx_hash, evt_index FROM uniswap_v4_worldchain.base_trades
    WHERE hooks IN (0xb216070c3509047ea597e2e626a29cea427a60c8, 0x0f41715dc432692b66a5adf8dcfef6ac407b20c8, 0xbb021554c5294328b04fa313669715bd201ba040, 0x03d482cb3ff339c2d29736818d0f72c66dd6a040) AND block_number >= 33384712 AND block_date >= DATE '2026-06-01'
    UNION ALL
    SELECT 'unichain' AS blockchain, tx_hash, evt_index FROM uniswap_v4_unichain.base_trades
    WHERE hooks IN (0xb216070c3509047ea597e2e626a29cea427a60c8, 0x0f41715dc432692b66a5adf8dcfef6ac407b20c8, 0xbb021554c5294328b04fa313669715bd201ba040, 0x03d482cb3ff339c2d29736818d0f72c66dd6a040) AND block_number >= 55356883 AND block_date >= DATE '2026-06-01'
    UNION ALL
    SELECT 'monad' AS blockchain, tx_hash, evt_index FROM uniswap_v4_monad.base_trades
    WHERE hooks IN (0xb216070c3509047ea597e2e626a29cea427a60c8, 0x0f41715dc432692b66a5adf8dcfef6ac407b20c8, 0xbb021554c5294328b04fa313669715bd201ba040, 0x03d482cb3ff339c2d29736818d0f72c66dd6a040) AND block_date >= DATE '2026-06-01'
    UNION ALL
    SELECT 'robinhood' AS blockchain, tx_hash, evt_index FROM uniswap_v4_robinhood.base_trades
    WHERE hooks IN (0xb216070c3509047ea597e2e626a29cea427a60c8, 0x0f41715dc432692b66a5adf8dcfef6ac407b20c8, 0xbb021554c5294328b04fa313669715bd201ba040, 0x03d482cb3ff339c2d29736818d0f72c66dd6a040) AND block_number >= 30206983 AND block_date >= DATE '2026-06-01'
    UNION ALL
    SELECT 'tempo' AS blockchain, tx_hash, evt_index FROM uniswap_v4_tempo.base_trades
    WHERE hooks IN (0xb216070c3509047ea597e2e626a29cea427a60c8, 0x0f41715dc432692b66a5adf8dcfef6ac407b20c8, 0xbb021554c5294328b04fa313669715bd201ba040, 0x03d482cb3ff339c2d29736818d0f72c66dd6a040) AND block_date >= DATE '2026-06-01'
)
, onchain_symbols (blockchain, token, symbol) AS (
    -- symbols fetched live from each chain's symbol() — Dune's token metadata
    -- has not indexed these fresh tokens yet, so dex.trades labels them NULL
    VALUES
        ('celo', 0x8ac2901dd8a1f17a1a4768a6ba4c3751e3995b2d, 'WBTC'),
        ('unichain', 0x15d0e0c55a3e7ee67152ad7e89acf164253ff68d, 'HYPE'),
        ('unichain', 0x8f187aa05619a017077f5308904739877ce9ea21, 'UNI'),
        ('robinhood', 0x6245e67affa44a23077f0ea7f981a8dc743a0c47, 'FRONG'),
        ('worldchain', 0x2cfc85d8e48f8eab294be644d9e25c3030863003, 'WLD'),
        ('monad', 0x01bff41798a0bcf287b996046ca68b395dbc1071, 'XAUt0'),
        ('monad', 0x98a22c11a74f8c92c5f7d5c00a6c235fc4e47777, 'Monadverse'),
        ('tempo', 0x20c00000000000000000000014f22ca97301eb73, 'USDT0'),
        ('tempo', 0x20c000000000000000000000b9537d11c60e8b50, 'USDC.e'),
        ('avalanche_c', 0xfe6b19286885a4f7f55adad09c3cd1f906d2478f, 'SOL'),
        ('arbitrum', 0xfa7f8980b0f1e64a2062791cc3b0871572f1f7f0, 'UNI'),
        ('optimism', 0x76fb31fb4af56892a25e32cfc43de717950c9278, 'AAVE'),
        ('polygon', 0xc2132d05d31c914a87c6611c10748aeb04b58e8f, 'USDT0'),
        ('ethereum', 0x6982508145454ce325ddbe47a25d4ec3d2311933, 'PEPE'),
        ('ethereum', 0xc72449e066d0a853d85a8c9b2b09a1463911df5f, 'GOOK'),
        ('robinhood', 0x0c5574e2f9732c94ff504206ab721bcfb4c4d9a3, 'ROOK'),
        ('base', 0x4ed4e862860bed51a9570b96d89af5e1b0efefed, 'DEGEN'),
        ('base', 0x191ca3a5130e79e2b0aba310ef52867ec9e0d155, 'BOOK'),
        ('bnb', 0x78724bcbb4c11db076d8458a2d3151c22132938b, 'GOOK'),
        ('bnb', 0xeccbb861c0dda7efd964010085488b69317e4444, '龙虾'),
        ('bnb', 0x6b282f1869382f74ead0c2f8615af57326815ca1, 'BOOK'),
        ('robinhood', 0x38a6ed4c95539fc424edf02c44c958ee794346e3, 'HPQT2'),
        ('robinhood', 0x2ec3f12f17652bf0ae600c889f0786821bcfc104, 'ROOK'),
        ('robinhood', 0x1c6f46789e170038219d05f297b5e0373d2cc14f, 'HPQT'),
        ('robinhood', 0xab9dff1ad19529c67283283987eb7e2b93efd282, 'HNY'),
        ('robinhood', 0x345a406795caf5aad3f268dc2ff4f5c243f2dc4c, 'HIVE'),
        ('robinhood', 0x34d362bd0356300378da3df7ce9f98031d51e58b, 'GLUE1'),
        ('robinhood', 0x5ab5473d40a67b6f38d03f9fe9e64bfd3ec3b8b8, 'BEE'),
        ('robinhood', 0xa6eae0a58a5f486bb96223a64b4fc3492f415884, 'BEE'),
        ('robinhood', 0x0ab4c8d68df065997d0194e207b4b723e83cfa3b, 'TEST2'),
        ('robinhood', 0x8de413a7ab76d5a5712470fc468167cbad16acbb, 'GOOK')
)
, labeled AS (
    SELECT
        d.blockchain,
        d.block_time,
        COALESCE(d.amount_usd, 0) AS amount_usd,
        -- ticker priority: Dune metadata -> live on-chain symbol() -> native symbol -> short address
        COALESCE(d.token_bought_symbol, ob.symbol, IF(d.token_bought_address = 0x0000000000000000000000000000000000000000, CASE d.blockchain WHEN 'celo' THEN 'CELO' WHEN 'bnb' THEN 'BNB' WHEN 'polygon' THEN 'POL' WHEN 'avalanche_c' THEN 'AVAX' WHEN 'monad' THEN 'MON' ELSE 'ETH' END), '0x' || LOWER(SUBSTR(TO_HEX(d.token_bought_address), 1, 8))) AS sym_b,
        COALESCE(d.token_sold_symbol, os.symbol, IF(d.token_sold_address = 0x0000000000000000000000000000000000000000, CASE d.blockchain WHEN 'celo' THEN 'CELO' WHEN 'bnb' THEN 'BNB' WHEN 'polygon' THEN 'POL' WHEN 'avalanche_c' THEN 'AVAX' WHEN 'monad' THEN 'MON' ELSE 'ETH' END), '0x' || LOWER(SUBSTR(TO_HEX(d.token_sold_address), 1, 8))) AS sym_s
    FROM dex.trades d
    JOIN glue_swaps g
      ON d.blockchain = g.blockchain AND d.tx_hash = g.tx_hash AND d.evt_index = g.evt_index
    LEFT JOIN onchain_symbols ob ON ob.blockchain = d.blockchain AND ob.token = d.token_bought_address
    LEFT JOIN onchain_symbols os ON os.blockchain = d.blockchain AND os.token = d.token_sold_address
    WHERE d.project = 'uniswap' AND d.version = '4' AND d.block_date >= DATE '2026-06-01'
)
SELECT
    blockchain,
    LEAST(sym_b, sym_s) || '-' || GREATEST(sym_b, sym_s) AS token_pair,
    SUM(amount_usd) AS volume_usd,
    COUNT(*) AS swaps,
    MAX(block_time) AS last_swap
FROM labeled
GROUP BY 1, 2
ORDER BY volume_usd DESC
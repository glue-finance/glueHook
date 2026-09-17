WITH glue_swaps AS (
    SELECT 'ethereum' AS blockchain, tx_hash, evt_index FROM uniswap_v4_ethereum.base_trades
    WHERE hooks IN (0xb216070c3509047ea597e2e626a29cea427a60c8, 0x0f41715dc432692b66a5adf8dcfef6ac407b20c8, 0x03d482cb3ff339c2d29736818d0f72c66dd6a040) AND block_number >= 25703029 AND block_date >= DATE '2026-06-01'
    UNION ALL
    SELECT 'base' AS blockchain, tx_hash, evt_index FROM uniswap_v4_base.base_trades
    WHERE hooks IN (0xb216070c3509047ea597e2e626a29cea427a60c8, 0x0f41715dc432692b66a5adf8dcfef6ac407b20c8, 0x03d482cb3ff339c2d29736818d0f72c66dd6a040) AND block_number >= 49657824 AND block_date >= DATE '2026-06-01'
    UNION ALL
    SELECT 'arbitrum' AS blockchain, tx_hash, evt_index FROM uniswap_v4_arbitrum.base_trades
    WHERE hooks IN (0xb216070c3509047ea597e2e626a29cea427a60c8, 0x0f41715dc432692b66a5adf8dcfef6ac407b20c8, 0x03d482cb3ff339c2d29736818d0f72c66dd6a040) AND block_number >= 492046075 AND block_date >= DATE '2026-06-01'
    UNION ALL
    SELECT 'optimism' AS blockchain, tx_hash, evt_index FROM uniswap_v4_optimism.base_trades
    WHERE hooks IN (0xb216070c3509047ea597e2e626a29cea427a60c8, 0x0f41715dc432692b66a5adf8dcfef6ac407b20c8, 0x03d482cb3ff339c2d29736818d0f72c66dd6a040) AND block_number >= 155253116 AND block_date >= DATE '2026-06-01'
    UNION ALL
    SELECT 'bnb' AS blockchain, tx_hash, evt_index FROM uniswap_v4_bnb.base_trades
    WHERE hooks IN (0xb216070c3509047ea597e2e626a29cea427a60c8, 0x0f41715dc432692b66a5adf8dcfef6ac407b20c8, 0x03d482cb3ff339c2d29736818d0f72c66dd6a040) AND block_number >= 114546905 AND block_date >= DATE '2026-06-01'
    UNION ALL
    SELECT 'polygon' AS blockchain, tx_hash, evt_index FROM uniswap_v4_polygon.base_trades
    WHERE hooks IN (0xb216070c3509047ea597e2e626a29cea427a60c8, 0x0f41715dc432692b66a5adf8dcfef6ac407b20c8, 0x03d482cb3ff339c2d29736818d0f72c66dd6a040) AND block_number >= 91600016 AND block_date >= DATE '2026-06-01'
    UNION ALL
    SELECT 'avalanche_c' AS blockchain, tx_hash, evt_index FROM uniswap_v4_avalanche_c.base_trades
    WHERE hooks IN (0xb216070c3509047ea597e2e626a29cea427a60c8, 0x0f41715dc432692b66a5adf8dcfef6ac407b20c8, 0x03d482cb3ff339c2d29736818d0f72c66dd6a040) AND block_number >= 92242906 AND block_date >= DATE '2026-06-01'
    UNION ALL
    SELECT 'blast' AS blockchain, tx_hash, evt_index FROM uniswap_v4_blast.base_trades
    WHERE hooks IN (0xb216070c3509047ea597e2e626a29cea427a60c8, 0x0f41715dc432692b66a5adf8dcfef6ac407b20c8, 0x03d482cb3ff339c2d29736818d0f72c66dd6a040) AND block_date >= DATE '2026-06-01'
    UNION ALL
    SELECT 'celo' AS blockchain, tx_hash, evt_index FROM uniswap_v4_celo.base_trades
    WHERE hooks IN (0xb216070c3509047ea597e2e626a29cea427a60c8, 0x0f41715dc432692b66a5adf8dcfef6ac407b20c8, 0x03d482cb3ff339c2d29736818d0f72c66dd6a040) AND block_date >= DATE '2026-06-01'
    UNION ALL
    SELECT 'zora' AS blockchain, tx_hash, evt_index FROM uniswap_v4_zora.base_trades
    WHERE hooks IN (0xb216070c3509047ea597e2e626a29cea427a60c8, 0x0f41715dc432692b66a5adf8dcfef6ac407b20c8, 0x03d482cb3ff339c2d29736818d0f72c66dd6a040) AND block_date >= DATE '2026-06-01'
    UNION ALL
    SELECT 'worldchain' AS blockchain, tx_hash, evt_index FROM uniswap_v4_worldchain.base_trades
    WHERE hooks IN (0xb216070c3509047ea597e2e626a29cea427a60c8, 0x0f41715dc432692b66a5adf8dcfef6ac407b20c8, 0x03d482cb3ff339c2d29736818d0f72c66dd6a040) AND block_number >= 33384712 AND block_date >= DATE '2026-06-01'
    UNION ALL
    SELECT 'unichain' AS blockchain, tx_hash, evt_index FROM uniswap_v4_unichain.base_trades
    WHERE hooks IN (0xb216070c3509047ea597e2e626a29cea427a60c8, 0x0f41715dc432692b66a5adf8dcfef6ac407b20c8, 0x03d482cb3ff339c2d29736818d0f72c66dd6a040) AND block_number >= 55356883 AND block_date >= DATE '2026-06-01'
    UNION ALL
    SELECT 'monad' AS blockchain, tx_hash, evt_index FROM uniswap_v4_monad.base_trades
    WHERE hooks IN (0xb216070c3509047ea597e2e626a29cea427a60c8, 0x0f41715dc432692b66a5adf8dcfef6ac407b20c8, 0x03d482cb3ff339c2d29736818d0f72c66dd6a040) AND block_date >= DATE '2026-06-01'
    UNION ALL
    SELECT 'robinhood' AS blockchain, tx_hash, evt_index FROM uniswap_v4_robinhood.base_trades
    WHERE hooks IN (0xb216070c3509047ea597e2e626a29cea427a60c8, 0x0f41715dc432692b66a5adf8dcfef6ac407b20c8, 0x03d482cb3ff339c2d29736818d0f72c66dd6a040) AND block_number >= 30206983 AND block_date >= DATE '2026-06-01'
    UNION ALL
    SELECT 'tempo' AS blockchain, tx_hash, evt_index FROM uniswap_v4_tempo.base_trades
    WHERE hooks IN (0xb216070c3509047ea597e2e626a29cea427a60c8, 0x0f41715dc432692b66a5adf8dcfef6ac407b20c8, 0x03d482cb3ff339c2d29736818d0f72c66dd6a040) AND block_date >= DATE '2026-06-01'
)
SELECT
    date_trunc('day', d.block_time) AS day,
    SUM(COALESCE(d.amount_usd, 0)) AS volume_usd,
    COUNT(*) AS swaps,
    SUM(SUM(COALESCE(d.amount_usd, 0))) OVER (ORDER BY date_trunc('day', d.block_time)) AS cumulative_volume_usd
FROM dex.trades d
JOIN glue_swaps g
  ON d.blockchain = g.blockchain AND d.tx_hash = g.tx_hash AND d.evt_index = g.evt_index
WHERE d.project = 'uniswap' AND d.version = '4' AND d.block_date >= DATE '2026-06-01'
GROUP BY 1
ORDER BY 1
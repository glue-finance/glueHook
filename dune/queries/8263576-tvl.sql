WITH pools AS (
    SELECT 'ethereum' AS blockchain, id, currency0 AS token0, currency1 AS token1 FROM uniswap_v4_ethereum.PoolManager_evt_Initialize WHERE hooks IN (0xb216070c3509047ea597e2e626a29cea427a60c8, 0x0f41715dc432692b66a5adf8dcfef6ac407b20c8, 0x03d482cb3ff339c2d29736818d0f72c66dd6a040)
    UNION ALL
    SELECT 'base' AS blockchain, id, currency0 AS token0, currency1 AS token1 FROM uniswap_v4_base.PoolManager_evt_Initialize WHERE hooks IN (0xb216070c3509047ea597e2e626a29cea427a60c8, 0x0f41715dc432692b66a5adf8dcfef6ac407b20c8, 0x03d482cb3ff339c2d29736818d0f72c66dd6a040)
    UNION ALL
    SELECT 'arbitrum' AS blockchain, id, currency0 AS token0, currency1 AS token1 FROM uniswap_v4_arbitrum.PoolManager_evt_Initialize WHERE hooks IN (0xb216070c3509047ea597e2e626a29cea427a60c8, 0x0f41715dc432692b66a5adf8dcfef6ac407b20c8, 0x03d482cb3ff339c2d29736818d0f72c66dd6a040)
    UNION ALL
    SELECT 'optimism' AS blockchain, id, currency0 AS token0, currency1 AS token1 FROM uniswap_v4_optimism.PoolManager_evt_Initialize WHERE hooks IN (0xb216070c3509047ea597e2e626a29cea427a60c8, 0x0f41715dc432692b66a5adf8dcfef6ac407b20c8, 0x03d482cb3ff339c2d29736818d0f72c66dd6a040)
    UNION ALL
    SELECT 'bnb' AS blockchain, id, currency0 AS token0, currency1 AS token1 FROM uniswap_v4_bnb.PoolManager_evt_Initialize WHERE hooks IN (0xb216070c3509047ea597e2e626a29cea427a60c8, 0x0f41715dc432692b66a5adf8dcfef6ac407b20c8, 0x03d482cb3ff339c2d29736818d0f72c66dd6a040)
    UNION ALL
    SELECT 'polygon' AS blockchain, id, currency0 AS token0, currency1 AS token1 FROM uniswap_v4_polygon.PoolManager_evt_Initialize WHERE hooks IN (0xb216070c3509047ea597e2e626a29cea427a60c8, 0x0f41715dc432692b66a5adf8dcfef6ac407b20c8, 0x03d482cb3ff339c2d29736818d0f72c66dd6a040)
    UNION ALL
    SELECT 'avalanche_c' AS blockchain, id, currency0 AS token0, currency1 AS token1 FROM uniswap_v4_avalanche_c.PoolManager_evt_Initialize WHERE hooks IN (0xb216070c3509047ea597e2e626a29cea427a60c8, 0x0f41715dc432692b66a5adf8dcfef6ac407b20c8, 0x03d482cb3ff339c2d29736818d0f72c66dd6a040)
    UNION ALL
    SELECT 'blast' AS blockchain, id, currency0 AS token0, currency1 AS token1 FROM uniswap_v4_blast.PoolManager_evt_Initialize WHERE hooks IN (0xb216070c3509047ea597e2e626a29cea427a60c8, 0x0f41715dc432692b66a5adf8dcfef6ac407b20c8, 0x03d482cb3ff339c2d29736818d0f72c66dd6a040)
    UNION ALL
    SELECT 'celo' AS blockchain, id, currency0 AS token0, currency1 AS token1 FROM uniswap_v4_celo.PoolManager_evt_Initialize WHERE hooks IN (0xb216070c3509047ea597e2e626a29cea427a60c8, 0x0f41715dc432692b66a5adf8dcfef6ac407b20c8, 0x03d482cb3ff339c2d29736818d0f72c66dd6a040)
    UNION ALL
    SELECT 'zora' AS blockchain, id, currency0 AS token0, currency1 AS token1 FROM uniswap_v4_zora.PoolManager_evt_Initialize WHERE hooks IN (0xb216070c3509047ea597e2e626a29cea427a60c8, 0x0f41715dc432692b66a5adf8dcfef6ac407b20c8, 0x03d482cb3ff339c2d29736818d0f72c66dd6a040)
    UNION ALL
    SELECT 'worldchain' AS blockchain, id, currency0 AS token0, currency1 AS token1 FROM uniswap_v4_worldchain.PoolManager_evt_Initialize WHERE hooks IN (0xb216070c3509047ea597e2e626a29cea427a60c8, 0x0f41715dc432692b66a5adf8dcfef6ac407b20c8, 0x03d482cb3ff339c2d29736818d0f72c66dd6a040)
    UNION ALL
    SELECT 'unichain' AS blockchain, id, currency0 AS token0, currency1 AS token1 FROM uniswap_v4_unichain.PoolManager_evt_Initialize WHERE hooks IN (0xb216070c3509047ea597e2e626a29cea427a60c8, 0x0f41715dc432692b66a5adf8dcfef6ac407b20c8, 0x03d482cb3ff339c2d29736818d0f72c66dd6a040)
    UNION ALL
    SELECT 'monad' AS blockchain, id, currency0 AS token0, currency1 AS token1 FROM uniswap_v4_monad.PoolManager_evt_Initialize WHERE hooks IN (0xb216070c3509047ea597e2e626a29cea427a60c8, 0x0f41715dc432692b66a5adf8dcfef6ac407b20c8, 0x03d482cb3ff339c2d29736818d0f72c66dd6a040)
    UNION ALL
    SELECT 'robinhood' AS blockchain, id, currency0 AS token0, currency1 AS token1 FROM uniswap_v4_robinhood.PoolManager_evt_Initialize WHERE hooks IN (0xb216070c3509047ea597e2e626a29cea427a60c8, 0x0f41715dc432692b66a5adf8dcfef6ac407b20c8, 0x03d482cb3ff339c2d29736818d0f72c66dd6a040)
    UNION ALL
    SELECT 'tempo' AS blockchain, id, currency0 AS token0, currency1 AS token1 FROM uniswap_v4_tempo.PoolManager_evt_Initialize WHERE hooks IN (0xb216070c3509047ea597e2e626a29cea427a60c8, 0x0f41715dc432692b66a5adf8dcfef6ac407b20c8, 0x03d482cb3ff339c2d29736818d0f72c66dd6a040)
),
snaps AS (
    SELECT 'ethereum' AS blockchain, id, block_date, block_time, evt_index, CAST(liquiditydelta AS DOUBLE) AS L, CAST(sqrtpricex96 AS DOUBLE) AS sqrtpricex96 FROM uniswap_v4_ethereum.base_liquidity_events
    WHERE event_type = 'swap' AND block_number >= 25703029 AND block_date >= DATE '2026-06-01'
    UNION ALL
    SELECT 'base' AS blockchain, id, block_date, block_time, evt_index, CAST(liquiditydelta AS DOUBLE) AS L, CAST(sqrtpricex96 AS DOUBLE) AS sqrtpricex96 FROM uniswap_v4_base.base_liquidity_events
    WHERE event_type = 'swap' AND block_number >= 49657824 AND block_date >= DATE '2026-06-01'
    UNION ALL
    SELECT 'arbitrum' AS blockchain, id, block_date, block_time, evt_index, CAST(liquiditydelta AS DOUBLE) AS L, CAST(sqrtpricex96 AS DOUBLE) AS sqrtpricex96 FROM uniswap_v4_arbitrum.base_liquidity_events
    WHERE event_type = 'swap' AND block_number >= 492046075 AND block_date >= DATE '2026-06-01'
    UNION ALL
    SELECT 'optimism' AS blockchain, id, block_date, block_time, evt_index, CAST(liquiditydelta AS DOUBLE) AS L, CAST(sqrtpricex96 AS DOUBLE) AS sqrtpricex96 FROM uniswap_v4_optimism.base_liquidity_events
    WHERE event_type = 'swap' AND block_number >= 155253116 AND block_date >= DATE '2026-06-01'
    UNION ALL
    SELECT 'bnb' AS blockchain, id, block_date, block_time, evt_index, CAST(liquiditydelta AS DOUBLE) AS L, CAST(sqrtpricex96 AS DOUBLE) AS sqrtpricex96 FROM uniswap_v4_bnb.base_liquidity_events
    WHERE event_type = 'swap' AND block_number >= 114546905 AND block_date >= DATE '2026-06-01'
    UNION ALL
    SELECT 'polygon' AS blockchain, id, block_date, block_time, evt_index, CAST(liquiditydelta AS DOUBLE) AS L, CAST(sqrtpricex96 AS DOUBLE) AS sqrtpricex96 FROM uniswap_v4_polygon.base_liquidity_events
    WHERE event_type = 'swap' AND block_number >= 91600016 AND block_date >= DATE '2026-06-01'
    UNION ALL
    SELECT 'avalanche_c' AS blockchain, id, block_date, block_time, evt_index, CAST(liquiditydelta AS DOUBLE) AS L, CAST(sqrtpricex96 AS DOUBLE) AS sqrtpricex96 FROM uniswap_v4_avalanche_c.base_liquidity_events
    WHERE event_type = 'swap' AND block_number >= 92242906 AND block_date >= DATE '2026-06-01'
    UNION ALL
    SELECT 'blast' AS blockchain, id, block_date, block_time, evt_index, CAST(liquiditydelta AS DOUBLE) AS L, CAST(sqrtpricex96 AS DOUBLE) AS sqrtpricex96 FROM uniswap_v4_blast.base_liquidity_events
    WHERE event_type = 'swap' AND block_date >= DATE '2026-06-01'
    UNION ALL
    SELECT 'celo' AS blockchain, id, block_date, block_time, evt_index, CAST(liquiditydelta AS DOUBLE) AS L, CAST(sqrtpricex96 AS DOUBLE) AS sqrtpricex96 FROM uniswap_v4_celo.base_liquidity_events
    WHERE event_type = 'swap' AND block_date >= DATE '2026-06-01'
    UNION ALL
    SELECT 'zora' AS blockchain, id, block_date, block_time, evt_index, CAST(liquiditydelta AS DOUBLE) AS L, CAST(sqrtpricex96 AS DOUBLE) AS sqrtpricex96 FROM uniswap_v4_zora.base_liquidity_events
    WHERE event_type = 'swap' AND block_date >= DATE '2026-06-01'
    UNION ALL
    SELECT 'worldchain' AS blockchain, id, block_date, block_time, evt_index, CAST(liquiditydelta AS DOUBLE) AS L, CAST(sqrtpricex96 AS DOUBLE) AS sqrtpricex96 FROM uniswap_v4_worldchain.base_liquidity_events
    WHERE event_type = 'swap' AND block_number >= 33384712 AND block_date >= DATE '2026-06-01'
    UNION ALL
    SELECT 'unichain' AS blockchain, id, block_date, block_time, evt_index, CAST(liquiditydelta AS DOUBLE) AS L, CAST(sqrtpricex96 AS DOUBLE) AS sqrtpricex96 FROM uniswap_v4_unichain.base_liquidity_events
    WHERE event_type = 'swap' AND block_number >= 55356883 AND block_date >= DATE '2026-06-01'
    UNION ALL
    SELECT 'monad' AS blockchain, id, block_date, block_time, evt_index, CAST(liquiditydelta AS DOUBLE) AS L, CAST(sqrtpricex96 AS DOUBLE) AS sqrtpricex96 FROM uniswap_v4_monad.base_liquidity_events
    WHERE event_type = 'swap' AND block_date >= DATE '2026-06-01'
    UNION ALL
    SELECT 'robinhood' AS blockchain, id, CAST(evt_block_time AS DATE) AS block_date, evt_block_time AS block_time, evt_index, CAST(liquidity AS DOUBLE) AS L, CAST(sqrtPriceX96 AS DOUBLE) AS sqrtpricex96 FROM uniswap_v4_robinhood.PoolManager_evt_Swap
    WHERE evt_block_time >= DATE '2026-06-01' AND liquidity > 0
    UNION ALL
    SELECT 'tempo' AS blockchain, id, CAST(evt_block_time AS DATE) AS block_date, evt_block_time AS block_time, evt_index, CAST(liquidity AS DOUBLE) AS L, CAST(sqrtPriceX96 AS DOUBLE) AS sqrtpricex96 FROM uniswap_v4_tempo.PoolManager_evt_Swap
    WHERE evt_block_time >= DATE '2026-06-01' AND liquidity > 0
),
daily AS (
    SELECT s.blockchain, s.id, s.block_date AS day, s.L, s.sqrtpricex96
    FROM (
        SELECT *, ROW_NUMBER() OVER (PARTITION BY blockchain, id, block_date ORDER BY block_time DESC, evt_index DESC) AS rn
        FROM snaps
    ) s
    JOIN pools p ON p.blockchain = s.blockchain AND p.id = s.id
    WHERE s.rn = 1
),
days AS (
    SELECT CAST(d.timestamp AS DATE) AS day
    FROM utils.days d
    WHERE d.timestamp >= (SELECT MIN(day) FROM daily) AND d.timestamp <= CURRENT_DATE
),
grid AS (
    SELECT dy.day, p.blockchain, p.id, p.token0, p.token1
    FROM days dy CROSS JOIN pools p
),
filled AS (
    SELECT g.day, g.blockchain, g.id, g.token0, g.token1,
        LAST_VALUE(d.L) IGNORE NULLS OVER (PARTITION BY g.blockchain, g.id ORDER BY g.day
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS L,
        LAST_VALUE(d.sqrtpricex96) IGNORE NULLS OVER (PARTITION BY g.blockchain, g.id ORDER BY g.day
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS sqrtp
    FROM grid g
    LEFT JOIN daily d ON d.blockchain = g.blockchain AND d.id = g.id AND d.day = g.day
),
nat AS (
    -- v4 PoolKey uses 0x0 for the chain's native token, but Dune's price feeds don't
    -- always price it there: ETH-native chains (incl. Robinhood/Blast/Zora, which have
    -- no own-chain native feed) read ETH's canonical ethereum price; Polygon prices POL
    -- at 0x...1010; Celo prices CELO at its ERC20 address
    SELECT * FROM (VALUES
        ('ethereum',    'ethereum', 0x0000000000000000000000000000000000000000),
        ('base',        'ethereum', 0x0000000000000000000000000000000000000000),
        ('arbitrum',    'ethereum', 0x0000000000000000000000000000000000000000),
        ('optimism',    'ethereum', 0x0000000000000000000000000000000000000000),
        ('blast',       'ethereum', 0x0000000000000000000000000000000000000000),
        ('zora',        'ethereum', 0x0000000000000000000000000000000000000000),
        ('worldchain',  'ethereum', 0x0000000000000000000000000000000000000000),
        ('unichain',    'ethereum', 0x0000000000000000000000000000000000000000),
        ('robinhood',   'ethereum', 0x0000000000000000000000000000000000000000),
        ('tempo',       'ethereum', 0x0000000000000000000000000000000000000000),
        ('bnb',         'bnb', 0x0000000000000000000000000000000000000000),
        ('avalanche_c', 'avalanche_c', 0x0000000000000000000000000000000000000000),
        ('monad',       'monad', 0x0000000000000000000000000000000000000000),
        ('polygon',     'polygon', 0x0000000000000000000000000000000000001010),
        ('celo',        'celo', 0x471ece3750da237f93b8e339c536989b8978a438)
    ) AS t(blockchain, px_chain, px_addr)
),
want AS (
    SELECT blockchain AS px_chain, token0 AS px_addr FROM pools
    UNION SELECT blockchain, token1 FROM pools
    UNION SELECT px_chain, px_addr FROM nat
),
px AS (
    SELECT CAST(pr.timestamp AS DATE) AS day, pr.blockchain, pr.contract_address, pr.price, pr.decimals
    FROM prices.day pr
    JOIN want w ON w.px_chain = pr.blockchain AND w.px_addr = pr.contract_address
    WHERE pr.timestamp >= TIMESTAMP '2026-06-01'
),
valued AS (
    SELECT f.day, f.blockchain, f.id,
        (f.L / (f.sqrtp / POWER(2, 96))) / POWER(10, IF(f.token0 = 0x0000000000000000000000000000000000000000, 18, COALESCE(p0.decimals, 18))) * p0.price AS v0,
        (f.L * (f.sqrtp / POWER(2, 96))) / POWER(10, IF(f.token1 = 0x0000000000000000000000000000000000000000, 18, COALESCE(p1.decimals, 18))) * p1.price AS v1
    FROM filled f
    LEFT JOIN nat n0 ON f.token0 = 0x0000000000000000000000000000000000000000 AND n0.blockchain = f.blockchain
    LEFT JOIN nat n1 ON f.token1 = 0x0000000000000000000000000000000000000000 AND n1.blockchain = f.blockchain
    LEFT JOIN px p0 ON p0.day = f.day AND p0.blockchain = COALESCE(n0.px_chain, f.blockchain)
        AND p0.contract_address = COALESCE(n0.px_addr, f.token0)
    LEFT JOIN px p1 ON p1.day = f.day AND p1.blockchain = COALESCE(n1.px_chain, f.blockchain)
        AND p1.contract_address = COALESCE(n1.px_addr, f.token1)
    WHERE f.L IS NOT NULL AND f.sqrtp IS NOT NULL AND f.sqrtp > 0
),
tvl AS (
    -- price both sides when possible; when only one side has a feed, a balanced
    -- full-range position is worth 2x the priced side
    SELECT day, blockchain, id, COALESCE(v0, v1) + COALESCE(v1, v0) AS tvl_usd
    FROM valued
    WHERE v0 IS NOT NULL OR v1 IS NOT NULL
)
, daily_total AS (SELECT day, SUM(tvl_usd) AS tvl_usd FROM tvl GROUP BY 1)
SELECT
    (SELECT tvl_usd FROM daily_total ORDER BY day DESC LIMIT 1) AS tvl_now_usd,
    (SELECT tvl_usd FROM daily_total ORDER BY day DESC LIMIT 1)
      - COALESCE((SELECT tvl_usd FROM daily_total WHERE day <= CURRENT_DATE - INTERVAL '7' DAY ORDER BY day DESC LIMIT 1), 0) AS tvl_change_7d_usd,
    (SELECT tvl_usd FROM daily_total ORDER BY day DESC LIMIT 1)
      - COALESCE((SELECT tvl_usd FROM daily_total WHERE day <= CURRENT_DATE - INTERVAL '30' DAY ORDER BY day DESC LIMIT 1), 0) AS tvl_change_30d_usd
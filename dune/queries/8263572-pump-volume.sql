WITH pumps AS (
    SELECT 'ethereum' AS chain, topic1, data FROM ethereum.logs
    WHERE contract_address IN (0xb216070c3509047ea597e2e626a29cea427a60c8, 0x0f41715dc432692b66a5adf8dcfef6ac407b20c8, 0xbb021554c5294328b04fa313669715bd201ba040, 0x03d482cb3ff339c2d29736818d0f72c66dd6a040) AND topic0 = 0xef85bac7805b280938cdf45de486b073bb9da505f8733a5c0ff5dc9d741563c5 AND block_number >= 25703029 AND block_date >= DATE '2026-06-01'
    UNION ALL
    SELECT 'base' AS chain, topic1, data FROM base.logs
    WHERE contract_address IN (0xb216070c3509047ea597e2e626a29cea427a60c8, 0x0f41715dc432692b66a5adf8dcfef6ac407b20c8, 0xbb021554c5294328b04fa313669715bd201ba040, 0x03d482cb3ff339c2d29736818d0f72c66dd6a040) AND topic0 = 0xef85bac7805b280938cdf45de486b073bb9da505f8733a5c0ff5dc9d741563c5 AND block_number >= 49657824 AND block_date >= DATE '2026-06-01'
    UNION ALL
    SELECT 'arbitrum' AS chain, topic1, data FROM arbitrum.logs
    WHERE contract_address IN (0xb216070c3509047ea597e2e626a29cea427a60c8, 0x0f41715dc432692b66a5adf8dcfef6ac407b20c8, 0xbb021554c5294328b04fa313669715bd201ba040, 0x03d482cb3ff339c2d29736818d0f72c66dd6a040) AND topic0 = 0xef85bac7805b280938cdf45de486b073bb9da505f8733a5c0ff5dc9d741563c5 AND block_number >= 492046075 AND block_date >= DATE '2026-06-01'
    UNION ALL
    SELECT 'optimism' AS chain, topic1, data FROM optimism.logs
    WHERE contract_address IN (0xb216070c3509047ea597e2e626a29cea427a60c8, 0x0f41715dc432692b66a5adf8dcfef6ac407b20c8, 0xbb021554c5294328b04fa313669715bd201ba040, 0x03d482cb3ff339c2d29736818d0f72c66dd6a040) AND topic0 = 0xef85bac7805b280938cdf45de486b073bb9da505f8733a5c0ff5dc9d741563c5 AND block_number >= 155253116 AND block_date >= DATE '2026-06-01'
    UNION ALL
    SELECT 'bnb' AS chain, topic1, data FROM bnb.logs
    WHERE contract_address IN (0xb216070c3509047ea597e2e626a29cea427a60c8, 0x0f41715dc432692b66a5adf8dcfef6ac407b20c8, 0xbb021554c5294328b04fa313669715bd201ba040, 0x03d482cb3ff339c2d29736818d0f72c66dd6a040) AND topic0 = 0xef85bac7805b280938cdf45de486b073bb9da505f8733a5c0ff5dc9d741563c5 AND block_number >= 114546905 AND block_date >= DATE '2026-06-01'
    UNION ALL
    SELECT 'polygon' AS chain, topic1, data FROM polygon.logs
    WHERE contract_address IN (0xb216070c3509047ea597e2e626a29cea427a60c8, 0x0f41715dc432692b66a5adf8dcfef6ac407b20c8, 0xbb021554c5294328b04fa313669715bd201ba040, 0x03d482cb3ff339c2d29736818d0f72c66dd6a040) AND topic0 = 0xef85bac7805b280938cdf45de486b073bb9da505f8733a5c0ff5dc9d741563c5 AND block_number >= 91600016 AND block_date >= DATE '2026-06-01'
    UNION ALL
    SELECT 'avalanche_c' AS chain, topic1, data FROM avalanche_c.logs
    WHERE contract_address IN (0xb216070c3509047ea597e2e626a29cea427a60c8, 0x0f41715dc432692b66a5adf8dcfef6ac407b20c8, 0xbb021554c5294328b04fa313669715bd201ba040, 0x03d482cb3ff339c2d29736818d0f72c66dd6a040) AND topic0 = 0xef85bac7805b280938cdf45de486b073bb9da505f8733a5c0ff5dc9d741563c5 AND block_number >= 92242906 AND block_date >= DATE '2026-06-01'
    UNION ALL
    SELECT 'blast' AS chain, topic1, data FROM blast.logs
    WHERE contract_address IN (0xb216070c3509047ea597e2e626a29cea427a60c8, 0x0f41715dc432692b66a5adf8dcfef6ac407b20c8, 0xbb021554c5294328b04fa313669715bd201ba040, 0x03d482cb3ff339c2d29736818d0f72c66dd6a040) AND topic0 = 0xef85bac7805b280938cdf45de486b073bb9da505f8733a5c0ff5dc9d741563c5 AND block_date >= DATE '2026-06-01'
    UNION ALL
    SELECT 'celo' AS chain, topic1, data FROM celo.logs
    WHERE contract_address IN (0xb216070c3509047ea597e2e626a29cea427a60c8, 0x0f41715dc432692b66a5adf8dcfef6ac407b20c8, 0xbb021554c5294328b04fa313669715bd201ba040, 0x03d482cb3ff339c2d29736818d0f72c66dd6a040) AND topic0 = 0xef85bac7805b280938cdf45de486b073bb9da505f8733a5c0ff5dc9d741563c5 AND block_date >= DATE '2026-06-01'
    UNION ALL
    SELECT 'zora' AS chain, topic1, data FROM zora.logs
    WHERE contract_address IN (0xb216070c3509047ea597e2e626a29cea427a60c8, 0x0f41715dc432692b66a5adf8dcfef6ac407b20c8, 0xbb021554c5294328b04fa313669715bd201ba040, 0x03d482cb3ff339c2d29736818d0f72c66dd6a040) AND topic0 = 0xef85bac7805b280938cdf45de486b073bb9da505f8733a5c0ff5dc9d741563c5 AND block_date >= DATE '2026-06-01'
    UNION ALL
    SELECT 'worldchain' AS chain, topic1, data FROM worldchain.logs
    WHERE contract_address IN (0xb216070c3509047ea597e2e626a29cea427a60c8, 0x0f41715dc432692b66a5adf8dcfef6ac407b20c8, 0xbb021554c5294328b04fa313669715bd201ba040, 0x03d482cb3ff339c2d29736818d0f72c66dd6a040) AND topic0 = 0xef85bac7805b280938cdf45de486b073bb9da505f8733a5c0ff5dc9d741563c5 AND block_number >= 33384712 AND block_date >= DATE '2026-06-01'
    UNION ALL
    SELECT 'unichain' AS chain, topic1, data FROM unichain.logs
    WHERE contract_address IN (0xb216070c3509047ea597e2e626a29cea427a60c8, 0x0f41715dc432692b66a5adf8dcfef6ac407b20c8, 0xbb021554c5294328b04fa313669715bd201ba040, 0x03d482cb3ff339c2d29736818d0f72c66dd6a040) AND topic0 = 0xef85bac7805b280938cdf45de486b073bb9da505f8733a5c0ff5dc9d741563c5 AND block_number >= 55356883 AND block_date >= DATE '2026-06-01'
    UNION ALL
    SELECT 'monad' AS chain, topic1, data FROM monad.logs
    WHERE contract_address IN (0xb216070c3509047ea597e2e626a29cea427a60c8, 0x0f41715dc432692b66a5adf8dcfef6ac407b20c8, 0xbb021554c5294328b04fa313669715bd201ba040, 0x03d482cb3ff339c2d29736818d0f72c66dd6a040) AND topic0 = 0xef85bac7805b280938cdf45de486b073bb9da505f8733a5c0ff5dc9d741563c5 AND block_date >= DATE '2026-06-01'
    UNION ALL
    SELECT 'robinhood' AS chain, topic1, data FROM robinhood.logs
    WHERE contract_address IN (0xb216070c3509047ea597e2e626a29cea427a60c8, 0x0f41715dc432692b66a5adf8dcfef6ac407b20c8, 0xbb021554c5294328b04fa313669715bd201ba040, 0x03d482cb3ff339c2d29736818d0f72c66dd6a040) AND topic0 = 0xef85bac7805b280938cdf45de486b073bb9da505f8733a5c0ff5dc9d741563c5 AND block_number >= 30206983 AND block_date >= DATE '2026-06-01'
    UNION ALL
    SELECT 'tempo' AS chain, topic1, data FROM tempo.logs
    WHERE contract_address IN (0xb216070c3509047ea597e2e626a29cea427a60c8, 0x0f41715dc432692b66a5adf8dcfef6ac407b20c8, 0xbb021554c5294328b04fa313669715bd201ba040, 0x03d482cb3ff339c2d29736818d0f72c66dd6a040) AND topic0 = 0xef85bac7805b280938cdf45de486b073bb9da505f8733a5c0ff5dc9d741563c5 AND block_date >= DATE '2026-06-01'
)
SELECT
    chain,
    topic1 AS pool_id,
    SUM(CAST(bytearray_to_uint256(bytearray_substring(data, 1, 32)) AS DOUBLE)) AS total_spent_raw,
    SUM(CAST(bytearray_to_uint256(bytearray_substring(data, 33, 32)) AS DOUBLE)) AS total_bought_raw,
    COUNT(*) AS pumps
FROM pumps
GROUP BY 1, 2
ORDER BY pumps DESC
# Pesquisa 20 — DynamoDB

## Pontos conferidos
- on-demand price cut 50% effective 1 Nov 2024, all Regions. global tables cut up to 67% (on-demand replicated writes -67%; provisioned replicated writes -33%). AWS positioned on-demand as default mode for most workloads. fonte: https://aws.amazon.com/about-aws/whats-new/2024/11/amazon-dynamo-db-reduces-prices-on-demand-throughput-global-tables
- "67%" is global tables only, not warm throughput. fonte: https://aws.amazon.com/blogs/database/new-amazon-dynamodb-lowers-pricing-for-on-demand-throughput-and-global-tables/
- TTL: attribute type Number, Unix epoch seconds. non-Number ignored. fonte: https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/TTL.html
- TTL deletion "typically within a few days after expiration", can occur any time; no write throughput consumed. fonte: https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/TTL.html
- expired items pending deletion still readable/updatable. use filter expressions in Query/Scan to hide them. recommend condition expression when updating expired item. fonte: https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/TTL.html
- updating TTL to future (or removing attribute) before deletion cancels expiry. fonte: https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/TTL.html
- TTL deletes go to Streams as service deletions (not user deletes); removed from LSIs/GSIs like normal deletes. fonte: https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/TTL.html
- global tables: TTL delete replicated; source Region no WCU, replica Regions consume replicated WCU/rWRU. fonte: https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/TTL.html
- Lambda event source mapping filter for TTL deletes only: pattern on `userIdentity` type `Service`, principalId `dynamodb.amazonaws.com`. up to 5 filters per mapping. fonte: https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/time-to-live-ttl-streams.html
- Streams retention: change log kept up to 24 hours. fonte: https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/Streams.html
- StreamViewType: KEYS_ONLY, NEW_IMAGE, OLD_IMAGE, NEW_AND_OLD_IMAGES. changing view type creates new stream (new ARN). fonte: https://docs.amazonaws.cn/AWSCloudFormation/latest/UserGuide/aws-properties-dynamodb-streamspecification.html
- Streams: up to 2 simultaneous readers per shard (single-Region, non-global); global tables: limit to 1. fonte: https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/ServiceQuotas.html
- NEW 19 Nov 2025: GSI multi-attribute composite keys. up to 4 partition-key attrs + 4 sort-key attrs (8 total). no extra charge. removes synthetic concatenated keys. GSI still sparse (item missing any key attr not indexed). CDK L2 support reported. fonte: https://aws.amazon.com/about-aws/whats-new/2025/11/amazon-dynamodb-multi-attribute-composite-keys-global-secondary-indexes
- per-partition ceiling: 3000 RCU / 1000 WCU per second; 10 GB per partition (secondary source). adaptive capacity can raise a hot partition up to those max. fonte: https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/burst-adaptive-capacity.html
- adaptive capacity won't split item collection across partitions if table has an LSI. fonte: https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/burst-adaptive-capacity.html

## Preços e limites (us-east-1, out/2026 consulta; page scrape incomplete, confirm in calculator)
- on-demand write: $0.625 per million WRU (1 WRU = up to 1 KB; transactional = 2 WRU/KB). fonte: https://aws.amazon.com/dynamodb/pricing/on-demand/
- on-demand read: $0.125 per million RRU (4 KB units; eventually consistent 0.5 RRU, strongly consistent 1, transactional 2). fonte: https://aws.amazon.com/dynamodb/pricing/on-demand/
- storage Standard $0.25/GB-month; Standard-IA $0.10/GB-month. first 25 GB free (Standard). fonte: https://aws.amazon.com/dynamodb/pricing/on-demand/
- Standard-IA: writes $0.780 per million, reads $0.155 per million (worked example). fonte: https://aws.amazon.com/dynamodb/pricing/on-demand/
- free tier provisioned: 25 WCU + 25 RCU. fonte: https://aws.amazon.com/dynamodb/pricing/on-demand/
- Streams reads $0.02 per 100,000 RRU; 2.5 million free/month; Lambda-triggered GetRecords not charged. fonte: https://aws.amazon.com/dynamodb/pricing/on-demand/
- PITR $0.20/GB-month; on-demand backup $0.10/GB-month; restore $0.15/GB. fonte: https://aws.amazon.com/dynamodb/pricing/on-demand/
- default quota per table: 40,000 RRU + 40,000 WRU (on-demand) / 40,000 RCU + 40,000 WCU (provisioned). per account provisioned: 80,000 RCU + 80,000 WCU. adjustable. fonte: https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/ServiceQuotas.html
- GSIs per table default 20; LSIs max 5. projected attributes max 100 combined (INCLUDE only). fonte: https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/ServiceQuotas.html
- tables per account per Region: 2,500 default (up to 10,000 via account team). no practical table size limit. fonte: https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/ServiceQuotas.html
- provisioned decreases: 4 at start of UTC day, +1 per hour (max 27/day). fonte: https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/ServiceQuotas.html
- size units are binary: 1 KB = 1024 bytes. fonte: https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/ServiceQuotas.html

## Não confirmado
- TTL delete price (page gave none; docs say no WCU consumed).
- max item size 400 KB, Query/Scan 1 MB page, transaction 100 items: not verified here (from memory); check https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/ServiceQuotas.html before stating.
- exact current on-demand rate on live pricing grid (scrape missed the grid).
- whether Streams reads consume table RCU (only third-party said no).
- Streams required NEW_AND_OLD_IMAGES for global tables (third-party only).

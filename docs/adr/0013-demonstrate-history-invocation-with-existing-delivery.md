# Demonstrate history-aware invocation with existing delivery

<a id="adr-0013"></a>

- On 8 October 2026 the owner requested generic Fabric history-aware invocation with external consumer evidence and durable application composition. The existing research consumer already combines Grind transactional admission and Fabric PostgreSQL records, so an additional public consumer there tests the new boundary without introducing another queue or replacing the existing publication pipeline.
- Application acceptance and Fabric admission occur at different commits. Existing transactional delivery covers that interval; Fabric's leased recovery owns an admitted run. Retaining its outcome until an idempotent application incorporation transaction commits covers the second interval.
- The application applied marker outlives Fabric pruning because retained execution identity alone cannot prevent a later delivery from creating a new run once the record is absent. The demonstration must test that boundary and lost incorporation acknowledgement independently of model quality.
- An application graph can retain an incorporation operation when the application supplies truthful idempotency and interrupted-effect handling. It does not make admission atomic with application acceptance; neither pool sharing nor a borrowed connection establishes the missing contract.

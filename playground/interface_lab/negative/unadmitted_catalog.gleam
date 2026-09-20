// THROWAWAY: Rendering this API requires explicit policy admission.
import lab/llm_catalog as catalog

pub fn invalid(tools: catalog.Catalog) {
  catalog.render(tools)
}

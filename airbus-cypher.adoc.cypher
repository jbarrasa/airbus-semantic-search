// This step is not needed since I provide the data in CSV format but add it in order to show how XML can be transformed into CSV  
// I manually copied a feed sample to github to guarantee reproducibility

with "https://raw.githubusercontent.com/jbarrasa/airbus-semantic-search/main/data/airbus-rss-feed.xml" as sample_feed
call apoc.load.xml(sample_feed,"rss/channel/item",{},true) yield value
with value._item[0]._text as title,value._item[1]._text as link, value._item[2]._text as desc, value._item[4]._text as pubDate, value._item[5]._text as author, value._item[6]._text as permlink
call apoc.load.html(permlink,{ text: "body article div.row"} ) yield value
return title, link, desc, pubDate, author, permlink, value.text[0].text as fultext


// Demo Starts here:

CREATE CONSTRAINT n10s_unique_uri ON (r:Resource) ASSERT r.uri IS UNIQUE;

call n10s.graphconfig.init({ handleVocabUris: "IGNORE", classLabel: "Concept", subClassOfRel: "broader"});

// this imports the ontology directly from github but you can import from your local drive since the onto is in the folder onto/aircraft.skos
call n10s.skos.import.fetch("https://github.com/jbarrasa/airbus-semantic-search/raw/main/onto/aircraft.skos","RDF/XML");

// explore the taxonomy...
match hierarchy = (n:Concept)-[:broader*3..4]->()
return hierarchy limit 3


// now we load the articles as CSV. 
// Again, this imports directly from github but can be done from local drive, csv file is in data directory
LOAD CSV WITH HEADERS FROM 'https://github.com/jbarrasa/airbus-semantic-search/raw/main/data/airbus-articles.csv' AS row
CREATE (a:Article) SET a = row


// we add a property where we select the elements in the article to be used for entity extraction
// in this case we choose the title and the description, the full text or any other combination would also be valid and return different results
MATCH (n:Article) set n.nlp_text = n.title + ' ' + n.desc


// Before we run the entity extraction step we’ll need to create an API key that has access to the Natural Language API. 
// Assuming that we’re already created a GCP account, we can generate a key by following the instructions at console.cloud.google.com/apis/credentials. 
// Once we’ve created a key, we’ll create a parameter that contains it:

:params key => ("<insert-key-here>")


// we run the entity extraction by invoking the GCP NLP services using the method apoc.nlp.gcp.entities
CALL apoc.periodic.iterate(
  "MATCH (a:Article)
   WHERE not(exists(a.processed))
   RETURN a",
  "CALL apoc.nlp.gcp.entities.stream([item in $_batch | item.a], {
     nodeProperty: 'nlp_text',
     key: $key
   })
   YIELD node, value
   SET node.processed = true
   WITH node, value
   UNWIND value.entities AS entity
   WITH entity, node
   WHERE not(entity.metadata.wikipedia_url is null)
   MERGE (c:Concept {altLabel: entity.metadata.wikipedia_url }) set c._name = entity.name , c._type = entity.type
   MERGE (node)-[:refers_to]->(c)",
  {batchMode: "BATCH_SINGLE", batchSize: 10, params: {key: $key}})
YIELD batches, total, timeTaken, committedOperations
RETURN batches, total, timeTaken, committedOperations;


//SEMANTIC SEARCH: Get results by entity, regardless of the syntax used in the article, or even the explicit mention of the concept.
match (airliner:Resource {uri: "http://www.wikidata.org/entity/Q309078"})
CALL n10s.inference.nodesInCategory(airliner, { inCatRel: "refers_to"}) yield node
return distinct node.title

// The pattern (path) can be returned with this cypher query...
// ...which can be used to create a search sentence in Bloom
match path = (airliner:Resource { prefLabel: $concept })<-[:broader*0..]-()<-[:refers_to]-()
return path


// SEMANTIC similarity calculations: given an article, return sementically similar ones
match chain = (a:Article {permlink: "https://www.airbus.com/en/newsroom/press-releases/2022-12-condor-takes-delivery-of-its-first-a330neo-to-modernise-fleet"})-[:refers_to]->()-[:broader*0..2]->()<-[:broader*0..2]-(:Resource)<-[:refers_to]-(other)
with distinct other.title as title, [x in nodes(chain) where x:Concept | x.prefLabel] as concepts
unwind concepts as concept
return title, count(distinct concept) as ct, collect(distinct concept) as list order by ct desc



//For completeness: The SPARQL query used to extract from wikidata (https://query.wikidata.org/) the taxonomies provided in the ontos directory

CONSTRUCT {
?item a skos:Concept ; skos:broader ?parentItem .
    ?item skos:prefLabel ?label .
    ?parentItem a skos:Concept; skos:prefLabel ?parentLabel .
    ?item skos:altLabel ?articleString .

}
WHERE
{
  ?item (wdt:P31|wdt:P279)* wd:Q11436 .
  ?item wdt:P31|wdt:P279 ?parentItem .
  ?item rdfs:label ?label .
  filter(lang(?label) = "en")
  ?parentItem rdfs:label ?parentLabel .
  filter(lang(?parentLabel) = "en")

  OPTIONAL {
      ?article schema:about ?item ;
            schema:inLanguage "en" ;
            schema:isPartOf <https://en.wikipedia.org/> .
    bind(str(?article) as ?articleString )
    }

}

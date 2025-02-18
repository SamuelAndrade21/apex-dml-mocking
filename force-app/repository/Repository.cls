public virtual without sharing class Repository implements IRepository {
  private final IDML dml;
  private final List<Schema.SObjectField> queryFields;
  private final Set<String> selectFields = new Set<String>();
  private final Map<Schema.SObjectField, String> childToRelationshipNames;

  protected final Schema.SObjectType repoType;
  protected final Map<String, Object> bindVars = new Map<String, Object>();
  protected System.AccessLevel accessLevel = System.AccessLevel.SYSTEM_MODE;
  protected final Map<String, RepositorySortOrder> fieldToSortOrder = new Map<String, RepositorySortOrder>();

  private Boolean shouldAddChildFields = true;
  private Integer limitAmount;
  private Boolean baseSelectUsed = false;

  public Repository(Schema.SObjectType repoType, List<Schema.SObjectField> queryFields, RepoFactory repoFactory) {
    this.dml = repoFactory.getDml();
    this.queryFields = queryFields;
    this.repoType = repoType;
    this.childToRelationshipNames = this.getChildRelationshipNames(repoType);
  }

  // SOQL
  public Database.QueryLocator getQueryLocator(List<Query> queries) {
    return this.getQueryLocator(queries, this.shouldAddChildFields);
  }

  /**
   * It's recommended that subqueries be removed from `Database.QueryLocator` instances (docs snippet below). This framework gives you the option
   * of ignoring that advice, but it'd be my recommendation that callers to `Repository.getQueryLocator` always pass `false` as the second argument.
   *
   * From the docs:
   *
   * > Batch Apex jobs run faster when the start method returns a `QueryLocator` object that doesn't include related records via a subquery.
   * > Avoiding relationship subqueries in a `QueryLocator` allows batch jobs to run using a faster, chunked implementation.
   * > If the start method returns an `Iterable` or a `QueryLocator` object with a relationship subquery, the batch job uses a slower, non-chunking, implementation
   *
   */
  public Database.QueryLocator getQueryLocator(List<Query> queries, Boolean shouldAddChildFields) {
    Boolean originalValue = this.shouldAddChildFields;
    this.shouldAddChildFields = shouldAddChildFields;
    Database.QueryLocator locator = Database.getQueryLocatorWithBinds(
      this.getFinalQuery(queries),
      this.bindVars,
      this.accessLevel
    );
    this.clearState();
    this.shouldAddChildFields = originalValue;

    return locator;
  }

  public virtual List<SObject> get(Query query) {
    return this.get(new List<Query>{ query });
  }

  public virtual List<SObject> get(List<Query> queries) {
    String finalQuery = this.getFinalQuery(queries);
    return this.performQuery(finalQuery);
  }

  public virtual List<SObject> getAll() {
    return this.get(new List<Query>());
  }

  public Repository setLimit(Integer limitAmount) {
    this.limitAmount = limitAmount;
    return this;
  }

  public Repository addSortOrder(Schema.SObjectField fieldToken, RepositorySortOrder sortOrder) {
    this.fieldToSortOrder.put(fieldToken.getDescribe().getName(), sortOrder);
    return this;
  }

  public Repository addParentFields(List<Schema.SObjectField> parentTypes, List<Schema.SObjectField> parentFields) {
    String parentBase = '';
    for (SObjectField parentId : parentTypes) {
      parentBase += parentId.getDescribe().getRelationshipName() + '.';
    }
    for (SObjectField parentField : parentFields) {
      this.selectFields.add(parentBase + parentField.getDescribe().getName());
    }
    return this;
  }

  public Repository addChildFields(Schema.SObjectField childFieldToken, List<Schema.SObjectField> childFields) {
    return this.addChildFields(
      childFieldToken,
      childFields,
      new List<Query>(),
      new Map<String, RepositorySortOrder>(),
      null
    );
  }

  public Repository addChildFields(
    Schema.SObjectField childFieldToken,
    List<Schema.SObjectField> childFields,
    List<Query> optionalWhereFilters,
    Map<String, RepositorySortOrder> fieldToSortOrder,
    Integer limitAmount
  ) {
    if (this.shouldAddChildFields == false || this.childToRelationshipNames.containsKey(childFieldToken) == false) {
      return this;
    }

    String baseSubselect =
      '(SELECT {0} FROM {1}' +
      this.addWheres(optionalWhereFilters) +
      this.getOrderBys(fieldToSortOrder) +
      this.getLimitAmount(limitAmount) +
      ')';

    Set<String> childFieldNames = new Set<String>{ 'Id' };
    for (SObjectField childField : childFields) {
      childFieldNames.add(childField.getDescribe().getName());
    }

    this.selectFields.add(
      String.format(
        baseSubselect,
        new List<String>{
          String.join(new List<String>(childFieldNames), ','),
          this.childToRelationshipNames.get(childFieldToken)
        }
      )
    );
    return this;
  }

  public Repository setAccessLevel(System.AccessLevel accessLevel) {
    this.setOptions(null, accessLevel);
    return this;
  }

  protected virtual Set<String> addSelectFields() {
    this.baseSelectUsed = true;
    Set<String> fieldStrings = new Set<String>{ 'Id' };
    for (SObjectField field : this.queryFields) {
      fieldStrings.add(field.getDescribe().getName());
    }
    return fieldStrings;
  }

  protected virtual String getFinalQuery(List<Query> queries) {
    return this.getSelectAndFrom() +
      this.addWheres(queries) +
      this.getOrderBys(this.fieldToSortOrder) +
      this.getLimitAmount(this.limitAmount);
  }

  protected virtual void clearState() {
    this.bindVars.clear();
    this.fieldToSortOrder.clear();
    this.limitAmount = null;
  }

  private Map<Schema.SObjectField, String> getChildRelationshipNames(Schema.SObjectType repoType) {
    Map<Schema.SObjectField, String> localChildToRelationshipNames = new Map<Schema.SObjectField, String>();
    for (Schema.ChildRelationship childRelationship : repoType.getDescribe().getChildRelationships()) {
      localChildToRelationshipNames.put(childRelationship.getField(), childRelationship.getRelationshipName());
    }
    return localChildToRelationshipNames;
  }

  private String getSelectAndFrom() {
    Set<String> localSelectFields = this.addSelectFields();
    if (this.baseSelectUsed) {
      localSelectFields.addAll(this.selectFields);
      this.baseSelectUsed = false;
    }
    return 'SELECT ' + String.join(new List<String>(localSelectFields), ', ') + '\nFROM ' + this.repoType;
  }

  private String addWheres(List<Query> queries) {
    List<String> wheres = new List<String>();
    for (Query qry : queries) {
      wheres.add(qry.toString());
      this.bindVars.putAll(qry.getBindVars());
    }
    return wheres.isEmpty() ? '' : '\nWHERE ' + String.join(wheres, '\nAND ');
  }

  private List<SObject> performQuery(String finalQuery) {
    System.debug('Query: \n' + finalQuery);
    List<SObject> results = Database.queryWithBinds(finalQuery, this.bindVars, this.accessLevel);
    this.clearState();
    System.debug('Number of results: ' + results.size() + '\nResults: \n' + results);
    return results;
  }

  private String getOrderBys(Map<String, RepositorySortOrder> sortOrders) {
    String orderByString = '';
    if (sortOrders.isEmpty() == false) {
      orderByString += ' \nORDER BY ';
      String separator = ', ';
      for (String fieldName : sortOrders.keySet()) {
        orderByString += fieldName + ' ' + sortOrders.get(fieldName).toString() + separator;
      }
      orderByString = orderByString.removeEnd(separator);
    }
    return orderByString;
  }

  private String getLimitAmount(Integer limitAmount) {
    return (limitAmount != null ? '\nLIMIT ' + limitAmount : '');
  }

  // DML
  public Database.SaveResult doInsert(SObject record) {
    return this.dml.doInsert(record);
  }
  public List<Database.SaveResult> doInsert(List<SObject> records) {
    return this.dml.doInsert(records);
  }

  public Database.SaveResult doUpdate(SObject record) {
    return this.dml.doUpdate(record);
  }
  public List<Database.SaveResult> doUpdate(List<SObject> records) {
    return this.dml.doUpdate(records);
  }

  public Database.UpsertResult doUpsert(SObject record) {
    return this.dml.doUpsert(record);
  }
  public List<Database.UpsertResult> doUpsert(List<SObject> records) {
    return this.dml.doUpsert(records);
  }
  public List<Database.UpsertResult> doUpsert(List<SObject> records, Schema.SObjectField field) {
    return this.dml.doUpsert(records, field);
  }

  public Database.UndeleteResult doUndelete(SObject record) {
    return this.dml.doUnDelete(record);
  }
  public List<Database.UndeleteResult> doUndelete(List<SObject> records) {
    return this.dml.doUndelete(records);
  }

  public Database.DeleteResult doDelete(SObject record) {
    return this.dml.doDelete(record);
  }
  public List<Database.DeleteResult> doDelete(List<SObject> records) {
    return this.dml.doDelete(records);
  }

  public Database.DeleteResult doHardDelete(SObject record) {
    return this.dml.doHardDelete(record);
  }
  public List<Database.DeleteResult> doHardDelete(List<SObject> records) {
    return this.dml.doHardDelete(records);
  }

  public Database.SaveResult publish(SObject event) {
    return this.dml.publish(event);
  }
  public List<Database.SaveResult> publish(List<SObject> events) {
    return this.dml.publish(events);
  }

  public IDML setOptions(Database.DMLOptions options, System.AccessLevel accessLevel) {
    this.accessLevel = accessLevel;
    return this.dml.setOptions(options, accessLevel);
  }
}

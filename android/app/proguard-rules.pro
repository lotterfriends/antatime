# Wird vom Flutter-Gradle-Plugin für Release-Builds (R8) automatisch eingebunden.

# WorkManager (BackgroundSyncWorker): Room lädt die generierte Datenbank
# (WorkDatabase_Impl) per Reflection über ihren Namen. Ohne diese Regel
# entfernt R8 sie, und die App stürzt beim Start ab
# ("Failed to create an instance of class androidx.work.impl.WorkDatabase").
-keep class * extends androidx.room.RoomDatabase { <init>(); }
-keep class androidx.work.impl.WorkDatabase_Impl { *; }

# Worker werden von WorkManager per Reflection über den Klassennamen erzeugt.
-keep class * extends androidx.work.ListenableWorker {
    public <init>(android.content.Context, androidx.work.WorkerParameters);
}

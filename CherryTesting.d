module CherryTesting;

import std.stdio;
import cherry.core;
import std.traits;

interface IA 
{
    void bf();
}

class A
{
    void func() {}
    void af() {}
    @property int nnn() const { return 0; }
}

class B : A, IA
{
    static void ss() {}
    static void ss(int a) {}

    override void func() {}
    void func(int x) {}
    override void bf() {}

    private void eee() {}

    @property int test() const { return t; }
    @property void test(int v) { t = v; }

private:
    int t;
}

class C : B
{
    void fun() {}
}

int main()
{
    enum members = __traits(derivedMembers, B);

    foreach(member; members) 
    {
        static if ( __traits(compiles, isSomeFunction!(__traits(getMember, B, member))) ) 
        {
            static if ( isSomeFunction!(__traits(getMember, B, member)) )
            {
                /*alias ov = MemberFunctionsTuple!(B, member);
                foreach (o; ov)*/
                foreach (o; __traits(getOverloads, B, member))
                    writeln(fullyQualifiedName!o);
            }
        }
    }
    
    readln;
    return 0;
}
